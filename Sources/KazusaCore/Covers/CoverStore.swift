// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
import ImageIO

/// 封面图片的本地缓存：`Covers/<游戏 id>.cover`，内容是原样的 JPEG / PNG 等图片数据。
///
/// 封面只存在 Kazusa 自己的数据目录里，不会写进游戏目录。
public struct CoverStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(paths: KazusaPaths) {
        self.init(directory: paths.coversDir)
    }

    public func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).cover")
    }

    public func hasCover(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    public func data(for id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    /// 保存封面。不是图片的数据（比如下载到一个 HTML 错误页）会被拒绝。
    public func save(_ data: Data, for id: UUID) throws {
        guard Self.isImage(data) else { throw CoverError.notAnImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: id), options: .atomic)
    }

    public func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// 能被 ImageIO 解码、且尺寸合理的图片。
    public static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return width >= 16 && height >= 16
    }
}

public enum CoverError: LocalizedError, Equatable {
    case notAnImage
    case notFound
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notAnImage: "这不是一张能识别的图片。"
        case .notFound: "没有找到这个游戏的封面。可以换个标题搜索，或者手动选择一张图片。"
        case .http(let code): "VNDB 返回了错误（HTTP \(code)），请稍后再试。"
        }
    }
}
