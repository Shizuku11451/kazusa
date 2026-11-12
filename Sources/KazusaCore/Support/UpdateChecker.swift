// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation

/// GitHub Releases 上的最新版本。没有开发者账号、没法签名公证，所以不自动替换 App，只把 dmg 交给浏览器下载。
public struct AppRelease: Equatable, Sendable {
    public var version: String
    public var notes: String
    /// dmg 的下载地址；发布里没有 dmg 时是发布页。
    public var downloadURL: URL

    static let latestURL = URL(string: "https://api.github.com/repos/Shizuku11451/kazusa/releases/latest")!

    public static func latest() async throws -> AppRelease {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> AppRelease {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        struct Release: Decodable { var tag_name: String; var body: String?; var html_url: URL; var assets: [Asset] }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let dmg = release.assets.first { $0.name.hasSuffix(".dmg") }?.browser_download_url
        return AppRelease(
            version: release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name,
            notes: release.body ?? "",
            downloadURL: dmg ?? release.html_url
        )
    }

    /// 按数字逐段比较版本号（"0.10.0" 比 "0.9.1" 新）。
    public func isNewer(than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
