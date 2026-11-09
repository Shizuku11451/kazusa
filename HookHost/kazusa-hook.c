// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451
//
// kazusa-hook：在游戏的 Wine 前缀里运行的小程序。加载 LunaHook 的 LunaHost32/64.dll，
// 把 LunaHook32/64.dll 注入到游戏进程，再把钩到的文本按行输出成 JSON（UTF-8）给 Kazusa。
//
// 用法：kazusa-hook32.exe [--pid N | --name Game.exe] [--codepage 932] [--wait 120] [--dll-dir 目录]
// LunaHost/LunaHook 的 DLL 默认在本程序旁边，也可以用 --dll-dir 指定（Windows 路径）。
//
// 输出（每行一个 JSON 对象）：
//   {"type":"ready","pid":1234}
//   {"type":"thread","id":"…","hookcode":"…","name":"…"}
//   {"type":"text","id":"…","text":"…"}
//   {"type":"info","level":0,"message":"…"}
//   {"type":"detached","pid":1234}
//   {"type":"error","message":"…"}
// 标准输入每行一条命令：
//   hook <特殊码>     插入 H 码
//   quit              断开并退出

#include <windows.h>
#include <tlhelp32.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#ifdef _WIN64
#define BITS L"64"
#else
#define BITS L"32"
#endif

// 和 LunaHook/include/types.h 的 ThreadParam 一致（MSVC 布局：uint64_t 按 8 字节对齐）。
typedef struct {
    DWORD processId;
    uint64_t addr;
    uint64_t ctx;
    uint64_t ctx2;
} ThreadParam;
_Static_assert(sizeof(ThreadParam) == 32, "ThreadParam 布局要和 MSVC 一致");
_Static_assert(offsetof(ThreadParam, addr) == 8, "ThreadParam 布局要和 MSVC 一致");

typedef void (*ProcessEvent)(DWORD);
typedef void (*ThreadEventEmbed)(const wchar_t *, const char *, ThreadParam, bool);
typedef void (*ThreadEvent)(const wchar_t *, const char *, ThreadParam);
typedef void (*OutputCallback)(const wchar_t *, const char *, ThreadParam, const wchar_t *);
typedef void (*HostInfoHandler)(int, const wchar_t *);
typedef void (*HookInsertHandler)(DWORD, uint64_t, const wchar_t *);
typedef void (*EmbedCallback)(const wchar_t *, ThreadParam);
typedef wchar_t *(*I18NQueryCallback)(const wchar_t *);
typedef void (*EmuGameInfoCallback)(const wchar_t *, const wchar_t *, const wchar_t *);

typedef void (*Luna_Start_t)(ProcessEvent, ProcessEvent, ThreadEventEmbed, ThreadEvent, OutputCallback,
                             HostInfoHandler, HookInsertHandler, EmbedCallback, I18NQueryCallback,
                             EmuGameInfoCallback);
typedef void (*Luna_Settings_t)(int, int, int, int, bool);
typedef void (*Luna_Pid_t)(DWORD);
typedef bool (*Luna_CheckIfNeedInject_t)(DWORD);
typedef void (*Luna_InsertHookCode_t)(DWORD, const wchar_t *);

static CRITICAL_SECTION outputLock;
static HANDLE detachedEvent;
static DWORD targetPid;

// MARK: - JSON 输出

static void put_json_string_utf8(const char *s) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*p < 0x20) printf("\\u%04x", *p);
            else putchar(*p);
        }
    }
    putchar('"');
}

static void put_json_string_wide(const wchar_t *w) {
    if (!w) w = L"";
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *buf = malloc(n > 0 ? n : 1);
    if (!buf) { fputs("\"\"", stdout); return; }
    if (n <= 0 || !WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, n, NULL, NULL)) buf[0] = 0;
    put_json_string_utf8(buf);
    free(buf);
}

static void put_thread_id(ThreadParam tp) {
    printf("\"%lu:%llx:%llx:%llx\"", (unsigned long)tp.processId, (unsigned long long)tp.addr,
           (unsigned long long)tp.ctx, (unsigned long long)tp.ctx2);
}

static void emit_error(const char *message) {
    EnterCriticalSection(&outputLock);
    fputs("{\"type\":\"error\",\"message\":", stdout);
    put_json_string_utf8(message);
    fputs("}\n", stdout);
    fflush(stdout);
    LeaveCriticalSection(&outputLock);
}

// MARK: - LunaHost 回调（在 LunaHost 自己的线程里调用）

static void on_connect(DWORD pid) {
    EnterCriticalSection(&outputLock);
    printf("{\"type\":\"ready\",\"pid\":%lu}\n", (unsigned long)pid);
    fflush(stdout);
    LeaveCriticalSection(&outputLock);
}

static void on_disconnect(DWORD pid) {
    EnterCriticalSection(&outputLock);
    printf("{\"type\":\"detached\",\"pid\":%lu}\n", (unsigned long)pid);
    fflush(stdout);
    LeaveCriticalSection(&outputLock);
    if (pid == targetPid) SetEvent(detachedEvent);
}

static void on_thread_create(const wchar_t *hookcode, const char *name, ThreadParam tp, bool embeddable) {
    (void)embeddable;
    EnterCriticalSection(&outputLock);
    fputs("{\"type\":\"thread\",\"id\":", stdout);
    put_thread_id(tp);
    fputs(",\"hookcode\":", stdout);
    put_json_string_wide(hookcode);
    fputs(",\"name\":", stdout);
    put_json_string_utf8(name ? name : "");
    fputs("}\n", stdout);
    fflush(stdout);
    LeaveCriticalSection(&outputLock);
}

static void on_thread_destroy(const wchar_t *hookcode, const char *name, ThreadParam tp) {
    (void)hookcode; (void)name;
    EnterCriticalSection(&outputLock);
    fputs("{\"type\":\"thread_removed\",\"id\":", stdout);
    put_thread_id(tp);
    fputs("}\n", stdout);
    fflush(stdout);
    LeaveCriticalSection(&outputLock);
}

static void on_output(const wchar_t *hookcode, const char *name, ThreadParam tp, const wchar_t *text) {
    (void)hookcode; (void)name;
    EnterCriticalSection(&outputLock);
    fputs("{\"type\":\"text\",\"id\":", stdout);
    put_thread_id(tp);
    fputs(",\"text\":", stdout);
    put_json_string_wide(text);
    fputs("}\n", stdout);
    fflush(stdout);
    LeaveCriticalSection(&outputLock);
}

static void on_host_info(int type, const wchar_t *log) {
    EnterCriticalSection(&outputLock);
    printf("{\"type\":\"info\",\"level\":%d,\"message\":", type);
    put_json_string_wide(log);
    fputs("}\n", stdout);
    fflush(stdout);
    LeaveCriticalSection(&outputLock);
}

static void on_hook_insert(DWORD pid, uint64_t address, const wchar_t *hookcode) {
    (void)pid; (void)address;
    EnterCriticalSection(&outputLock);
    fputs("{\"type\":\"hook_inserted\",\"hookcode\":", stdout);
    put_json_string_wide(hookcode);
    fputs("}\n", stdout);
    fflush(stdout);
    LeaveCriticalSection(&outputLock);
}

static void on_embed(const wchar_t *text, ThreadParam tp) { (void)text; (void)tp; }
static wchar_t *on_i18n_query(const wchar_t *text) { (void)text; return NULL; }
static void on_emu_game_info(const wchar_t *id, const wchar_t *title, const wchar_t *version) {
    (void)id; (void)title; (void)version;
}

// MARK: - 找进程、注入

static DWORD find_process(const wchar_t *name) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W entry = {.dwSize = sizeof(entry)};
    DWORD pid = 0;
    if (Process32FirstW(snapshot, &entry)) {
        do {
            if (!_wcsicmp(entry.szExeFile, name)) { pid = entry.th32ProcessID; break; }
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return pid;
}

/// 同位数注入：在目标进程里写入 DLL 路径，用 CreateRemoteThread 调 LoadLibraryW。
static bool inject_dll(DWORD pid, const wchar_t *dllPath) {
    HANDLE process = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pid);
    if (!process) return false;
    bool ok = false;
    SIZE_T size = (wcslen(dllPath) + 1) * sizeof(wchar_t);
    void *remote = VirtualAllocEx(process, NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (remote && WriteProcessMemory(process, remote, dllPath, size, NULL)) {
        LPTHREAD_START_ROUTINE loadLibrary =
            (LPTHREAD_START_ROUTINE)(void *)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW");
        HANDLE thread = CreateRemoteThread(process, NULL, 0, loadLibrary, remote, 0, NULL);
        if (thread) {
            WaitForSingleObject(thread, 10000);
            DWORD exitCode = 0;
            ok = GetExitCodeThread(thread, &exitCode) && exitCode != 0;
            CloseHandle(thread);
        }
    }
    if (remote) VirtualFreeEx(process, remote, 0, MEM_RELEASE);
    CloseHandle(process);
    return ok;
}

// MARK: - 标准输入命令

static Luna_InsertHookCode_t insertHookCode;
static Luna_Pid_t detachProcess;

static DWORD WINAPI stdin_loop(LPVOID unused) {
    (void)unused;
    char line[4096];
    while (fgets(line, sizeof(line), stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!strncmp(line, "hook ", 5)) {
            wchar_t code[4096];
            if (MultiByteToWideChar(CP_UTF8, 0, line + 5, -1, code, 4096) > 0) insertHookCode(targetPid, code);
        } else if (!strcmp(line, "quit")) {
            break;
        }
    }
    // 标准输入关闭（Kazusa 退出）也当作 quit。
    SetEvent(detachedEvent);
    return 0;
}

// MARK: - main

int wmain(int argc, wchar_t **argv) {
    InitializeCriticalSection(&outputLock);
    detachedEvent = CreateEventW(NULL, TRUE, FALSE, NULL);

    const wchar_t *processName = NULL;
    int codepage = 932;
    int waitSeconds = 120;
    const wchar_t *dllDir = NULL;
    for (int i = 1; i < argc; i++) {
        if (!wcscmp(argv[i], L"--pid") && i + 1 < argc) targetPid = wcstoul(argv[++i], NULL, 10);
        else if (!wcscmp(argv[i], L"--name") && i + 1 < argc) processName = argv[++i];
        else if (!wcscmp(argv[i], L"--codepage") && i + 1 < argc) codepage = _wtoi(argv[++i]);
        else if (!wcscmp(argv[i], L"--wait") && i + 1 < argc) waitSeconds = _wtoi(argv[++i]);
        else if (!wcscmp(argv[i], L"--dll-dir") && i + 1 < argc) dllDir = argv[++i];
    }
    if (!targetPid && !processName) {
        emit_error("用法：kazusa-hook.exe [--pid N | --name Game.exe] [--codepage 932] [--wait 120] [--dll-dir 目录]");
        return 2;
    }

    // DLL 默认放在本程序旁边。
    wchar_t dir[MAX_PATH];
    if (dllDir) {
        _snwprintf(dir, MAX_PATH, L"%ls", dllDir);
        size_t n = wcslen(dir);
        if (n > 0 && n + 1 < MAX_PATH && dir[n - 1] != L'\\' && dir[n - 1] != L'/') wcscat(dir, L"\\");
    } else {
        DWORD len = GetModuleFileNameW(NULL, dir, MAX_PATH);
        while (len > 0 && dir[len - 1] != L'\\' && dir[len - 1] != L'/') len--;
        dir[len] = 0;
    }
    wchar_t hostPath[MAX_PATH], hookPath[MAX_PATH];
    _snwprintf(hostPath, MAX_PATH, L"%lsLunaHost" BITS L".dll", dir);
    _snwprintf(hookPath, MAX_PATH, L"%lsLunaHook" BITS L".dll", dir);

    HMODULE host = LoadLibraryW(hostPath);
    if (!host) { emit_error("加载 LunaHost DLL 失败"); return 3; }
    Luna_Start_t start = (Luna_Start_t)(void *)GetProcAddress(host, "Luna_Start");
    Luna_Settings_t settings = (Luna_Settings_t)(void *)GetProcAddress(host, "Luna_Settings");
    Luna_Pid_t connect = (Luna_Pid_t)(void *)GetProcAddress(host, "Luna_ConnectProcess");
    Luna_CheckIfNeedInject_t needInject = (Luna_CheckIfNeedInject_t)(void *)GetProcAddress(host, "Luna_CheckIfNeedInject");
    insertHookCode = (Luna_InsertHookCode_t)(void *)GetProcAddress(host, "Luna_InsertHookCode");
    detachProcess = (Luna_Pid_t)(void *)GetProcAddress(host, "Luna_DetachProcess");
    if (!start || !settings || !connect || !needInject || !insertHookCode || !detachProcess) {
        emit_error("LunaHost DLL 缺少需要的导出函数");
        return 3;
    }

    // 游戏可能刚启动，按名字找的话多等一会儿。
    for (int i = 0; !targetPid && i < waitSeconds * 2; i++) {
        targetPid = find_process(processName);
        if (!targetPid) Sleep(500);
    }
    if (!targetPid) { emit_error("没找到游戏进程"); return 4; }

    // flushDelay（毫秒）：同一线程的文本在这段时间内没有新字符才输出一条。
    settings(120, codepage, 3000, 1000000, false);
    start(on_connect, on_disconnect, on_thread_create, on_thread_destroy, on_output, on_host_info,
          on_hook_insert, on_embed, on_i18n_query, on_emu_game_info);
    connect(targetPid);
    if (needInject(targetPid) && !inject_dll(targetPid, hookPath)) {
        emit_error("注入失败");
        return 5;
    }

    CloseHandle(CreateThread(NULL, 0, stdin_loop, NULL, 0, NULL));
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, targetPid);
    HANDLE waits[2] = {detachedEvent, process};
    WaitForMultipleObjects(process ? 2 : 1, waits, FALSE, INFINITE);
    detachProcess(targetPid);
    fflush(stdout);
    return 0;
}
