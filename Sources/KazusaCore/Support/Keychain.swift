// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Security

/// 把 API Key 存在 macOS 钥匙串里，不写进 JSON 配置。
public enum Keychain {
    static let service = "app.kazusa.llm"

    /// 读过的 Key 留在内存里，一次运行只碰一次钥匙串。
    nonisolated(unsafe) private static var cache: [UUID: String] = [:]
    private static let lock = NSLock()
    // 注意：钥匙串的“始终允许”按程序的 cdhash 记（分区列表），自签名的程序每次重新构建 cdhash 都会变，
    // 所以每个新构建第一次读 Key 时会问一次密码。只有用 Apple 开发者证书（按 Team ID 记）才能避免。

    public static func apiKey(for providerID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[providerID] { return cached }
        guard let key = readKey(for: providerID) else { return nil }
        cache[providerID] = key
        return key
    }

    private static func readKey(for providerID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setAPIKey(_ key: String?, for providerID: UUID) {
        lock.lock(); defer { lock.unlock() }
        cache[providerID] = key?.isEmpty == false ? key : nil
        store(key, for: providerID)
    }

    private static func store(_ key: String?, for providerID: UUID) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
