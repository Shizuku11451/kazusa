// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// 钩到的原始文本的清理和判断。
public enum HookText {
    /// 去掉注音标记（`<R空港|ここ>` → `空港`）、换行和首尾空白（含全角空格）。
    public static func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"<R([^|>]*)\|[^>]*>"#, with: "$1", options: .regularExpression)
        s = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 像不像要翻译的台词：至少含一个假名、汉字或全角标点。
    /// 用来过滤 `mv01`、`sepia.AMP` 这类资源文件名和调试字符串。
    public static func isDialogue(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 1000 else { return false }
        return text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, // CJK 标点、平假名、片假名
                 0x3400...0x4DBF, 0x4E00...0x9FFF, // 汉字
                 0xFF01...0xFF60: // 全角字符
                true
            default: false
            }
        }
    }
}

/// 从游戏的多路文本里挑出要翻译的那一路。
///
/// 同一句话经常从好几路同时到达（例如一路带注音标记、一路已经排好版），还有人名、菜单等其他路。
/// 默认按累计的有效字数选：对白那一路很快就会远远超过人名和菜单。
/// 用户也可以手动指定一路（`pinnedThreadID`）。
public struct HookThreadSelector: Sendable {
    public struct ThreadState: Equatable, Sendable, Identifiable {
        public var thread: HookThread
        public var lastText: String = ""
        /// 累计的有效字数。
        public var score: Int = 0
        public var id: String { thread.id }
    }

    public private(set) var threads: [ThreadState] = []
    public var pinnedThreadID: String?
    private var lastEmitted: String?

    public init() {}

    /// 当前用来翻译的那一路。
    public var activeThreadID: String? {
        if let pinnedThreadID { return pinnedThreadID }
        // 分数相同时保留先到的那一路，避免两路来回切换。
        return threads.reduce(nil as ThreadState?) { best, t in
            guard let best else { return t.score > 0 ? t : nil }
            return t.score > best.score ? t : best
        }?.id
    }

    public mutating func register(_ thread: HookThread) {
        if let i = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[i].thread = thread
        } else {
            threads.append(ThreadState(thread: thread))
        }
    }

    public mutating func remove(id: String) {
        threads.removeAll { $0.id == id }
        if pinnedThreadID == id { pinnedThreadID = nil }
    }

    /// 收到一段文本。返回需要翻译的文本（已清理），不需要翻译时返回 nil。
    public mutating func accept(threadID: String, text: String) -> String? {
        let cleaned = HookText.clean(text)
        guard HookText.isDialogue(cleaned) else { return nil }
        if !threads.contains(where: { $0.id == threadID }) {
            threads.append(ThreadState(thread: HookThread(id: threadID, hookcode: "", name: "")))
        }
        let i = threads.firstIndex { $0.id == threadID }!
        threads[i].lastText = cleaned
        threads[i].score += cleaned.count

        guard activeThreadID == threadID, cleaned != lastEmitted else { return nil }
        lastEmitted = cleaned
        return cleaned
    }
}
