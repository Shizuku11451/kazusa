#!/bin/sh
# 为某个 Wine 版本编译打过 Rosetta 补丁的 wow64cpu.dll。
#
# 用法：ThirdParty/wow64cpu-rosetta/build.sh <wine 版本> <运行时根目录>
#   例：build.sh 11.21 ~/Library/Application\ Support/Kazusa/Runtimes/wine-staging-11.21-osx64
#   运行时根目录下要有 lib/wine/x86_64-windows/ntdll.dll（Gcenx 的 tar.xz 构建是这样的布局；
#   .app 版本传 "Wine Staging.app/Contents/Resources/wine"）。
#
# 依赖：brew install mingw-w64
# 产物：prebuilt/wine-<版本>/wow64cpu.dll
#
# 改编自 kic99/TEW_IX_on_Mac 的 wow64cpu-rosetta-fix/build.sh。
set -eu
VER=${1:?Wine 版本，例如 11.21}
ROOT=${2:?运行时根目录}
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$ROOT/lib/wine/x86_64-windows"
WORK="${TMPDIR:-/tmp}/kazusa-wow64cpu-$VER"
OUT="$HERE/prebuilt/wine-$VER"
CC=x86_64-w64-mingw32-gcc; DLLTOOL=x86_64-w64-mingw32-dlltool; OBJDUMP=x86_64-w64-mingw32-objdump
command -v $CC >/dev/null || { echo "缺少 $CC：brew install mingw-w64"; exit 1; }
[ -f "$LIB/ntdll.dll" ] || { echo "在 $LIB 下没找到 Wine 的 DLL"; exit 1; }
mkdir -p "$WORK" "$OUT"

# 1. Wine 源码：只需要头文件和 dlls/wow64cpu
MAJOR=${VER%%.*}
SRC="$WORK/wine-$VER"
if [ ! -d "$SRC/include" ]; then
    curl -fL -o "$WORK/wine.tar.xz" "https://dl.winehq.org/wine/source/$MAJOR.x/wine-$VER.tar.xz"
    tar -xJf "$WORK/wine.tar.xz" -C "$WORK" "wine-$VER/include" "wine-$VER/dlls/wow64cpu"
    rm "$WORK/wine.tar.xz"
fi

# 2. 在副本上打补丁
cp "$SRC/dlls/wow64cpu/cpu.c" "$WORK/cpu.c"
patch -s "$WORK/cpu.c" "$HERE/wow64cpu-rosetta-farjump.patch"

# 3. 用运行时自带的 ntdll.dll / wow64.dll 生成导入库
for d in ntdll wow64; do
    { echo "LIBRARY $d.dll"; echo EXPORTS
      $OBJDUMP -p "$LIB/$d.dll" | awk '/\[Ordinal\/Name Pointer\] Table/{f=1;next} f&&/\+base\[/{print $NF}'; } > "$WORK/$d.def"
    $DLLTOOL -d "$WORK/$d.def" -l "$WORK/lib$d.a"
done
sed -n 's/^@ stdcall \(-norelay \)\{0,1\}\([A-Za-z_0-9]*\)(.*/\2/p' "$SRC/dlls/wow64cpu/wow64cpu.spec" \
    | { echo "LIBRARY wow64cpu.dll"; echo EXPORTS; cat; } > "$WORK/wow64cpu.def"

# 4. 编译、链接（镜像基址和 Wine 自己的构建一致）
GCCINC=$($CC -print-file-name=include)
$CC -c -O2 -nostdinc -isystem "$GCCINC" -I"$SRC/include" -I"$SRC/include/msvcrt" \
    -D__WINESRC__ -D__WINE_PE_BUILD -D_NO_CRT_STDIO_INLINE -DWINE_NO_LONG_TYPES -D_WIN32_WINNT=0x0a00 \
    -fno-strict-aliasing -fasynchronous-unwind-tables -Wall -Wno-unused \
    -o "$WORK/cpu.o" "$WORK/cpu.c"
$CC -shared -nostdlib -o "$OUT/wow64cpu.dll" "$WORK/cpu.o" "$WORK/wow64cpu.def" \
    -L"$WORK" -lwow64 -lntdll -Wl,--image-base,0x7a400000 -Wl,-e,DllMain

# 5. 标记为 Wine 内置 DLL（偏移 0x40 写入 "Wine builtin DLL\0"，和 winebuild 一样），
#    否则 wineboot 不会把它复制进新前缀。
printf 'Wine builtin DLL\000' | dd of="$OUT/wow64cpu.dll" bs=1 seek=64 conv=notrunc 2>/dev/null

(cd "$OUT" && shasum -a 256 wow64cpu.dll | tee SHA256SUMS)
echo "已生成 $OUT/wow64cpu.dll"
