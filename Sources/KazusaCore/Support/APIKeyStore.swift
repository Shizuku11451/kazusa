// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import Security

/// API Key 存在 apikeys.json（权限 600，只有当前用户能读），不放进 settings.json。
/// 没用钥匙串：自签名的程序每次重新构建，钥匙串都会按新的程序指纹（cdhash）再要一次登录密码，
/// 只有 Apple 开发者证书（按 Team ID 记）能避免。
public struct APIKeyStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static let shared = APIKeyStore(fileURL: KazusaPaths.default.root.appendingPathComponent("apikeys.json"))

    public func apiKey(for providerID: UUID) -> String? {
        if let key = all()[providerID.uuidString] { return key }
        return migrateFromKeychain(providerID)
    }

    /// 返回是否写成功。
    @discardableResult
    public func setAPIKey(_ key: String?, for providerID: UUID) -> Bool {
        if key?.isEmpty != false { deleteFromKeychain(providerID) }
        // 文件读不出来（比如手改坏了）就别写：整份写回会把其他服务的 Key 冲掉。
        guard var keys = try? JSONFile.read([String: String].self, from: fileURL) ?? [:] else { return false }
        keys[providerID.uuidString] = key?.isEmpty == false ? key : nil
        return write(keys)
    }

    private func all() -> [String: String] {
        (try? JSONFile.read([String: String].self, from: fileURL)) ?? [:]
    }

    private func write(_ keys: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(keys) else { return false }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 先建一个 600 权限的临时文件再换过去，文件任何时候都不会是别人可读的。
        let tmp = dir.appendingPathComponent(".apikeys-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(tmp.path, fileURL.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }

    // MARK: - 旧版本存在钥匙串里的 Key

    private static let keychainService = "app.kazusa.llm"
    /// 每个 Key 一次运行只去钥匙串找一次：用户点了“拒绝”就别再弹。
    nonisolated(unsafe) private static var triedKeychain: Set<UUID> = []
    private static let lock = NSLock()

    private static func keychainQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// 删除不读内容，不会弹窗。
    private func deleteFromKeychain(_ id: UUID) {
        SecItemDelete(Self.keychainQuery(id) as CFDictionary)
    }

    private func migrateFromKeychain(_ id: UUID) -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard Self.triedKeychain.insert(id).inserted else { return nil }
        var query = Self.keychainQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        // 写进文件成功了才删钥匙串里的，否则两边都没了。
        if setAPIKey(key, for: id) { deleteFromKeychain(id) }
        return key
    }
}
