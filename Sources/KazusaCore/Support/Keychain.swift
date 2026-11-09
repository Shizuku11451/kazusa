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
    /// 钥匙串条目的访问权限记的是“创建它的那个程序的签名”。旧版本（ad-hoc 签名，每次构建签名都不同）
    /// 存的 Key，新版本每次读都会弹窗要密码。读到之后用当前程序重新存一遍，权限就换成了现在的
    /// 证书签名，以后重新构建也不会再问。
    private static let resavedKey = "keychain.resaved.v1"

    public static func apiKey(for providerID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[providerID] { return cached }
        guard let key = readKey(for: providerID) else { return nil }
        cache[providerID] = key
        let defaults = UserDefaults.standard
        var resaved = Set(defaults.stringArray(forKey: resavedKey) ?? [])
        if Bundle.main.bundleIdentifier != nil, !resaved.contains(providerID.uuidString) {
            guard store(key, for: providerID) else { return key }
            resaved.insert(providerID.uuidString)
            defaults.set(Array(resaved), forKey: resavedKey)
        }
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

    @discardableResult
    private static func store(_ key: String?, for providerID: UUID) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
