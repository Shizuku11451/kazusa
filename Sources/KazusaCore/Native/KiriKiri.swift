// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Compression
import Foundation

/// krkr2：吉里吉里 2 / 吉里吉里 Z 的开源重实现，直接读 `data.xp3` 封包运行 KiriKiri 游戏。
///
/// 由 ThirdParty/krkr2/build.sh 构建（打了 Kazusa 的补丁：桌面窗口、出错时返回非 0），
/// 打包在 Kazusa.app/Contents/Resources/krkr2/krkr2.app 里。只有 arm64 版本。
public enum KiriKiri {
    /// 能不能交给 krkr2 跑。
    public enum Readiness: Equatable, Sendable {
        case ready
        /// 没有 `startup.tjs` 也没有 `data.xp3`（例如封包嵌在 exe 里）。
        case noData
        /// `data.xp3` 里找不到 `startup.tjs`，或者读出来不是文本：封包加了密，要用游戏自己的 exe 解。
        case encrypted

        public var explanation: String? {
            switch self {
            case .ready: nil
            case .noData: "游戏数据嵌在 exe 里，krkr2 读不了"
            case .encrypted: "封包加了密，krkr2 读不了"
            }
        }
    }

    public static func searchRoots() -> [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL {
            roots.append(resources.appendingPathComponent("krkr2", isDirectory: true))
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Native
            .deletingLastPathComponent() // KazusaCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
        roots.append(repo.appendingPathComponent("ThirdParty/krkr2/prebuilt", isDirectory: true))
        return roots
    }

    /// krkr2 只编了 arm64，Intel Mac 上没有。
    public static func binary(searchRoots: [URL] = searchRoots()) -> URL? {
        guard SystemCheck.isAppleSilicon else { return nil }
        return searchRoots
            .map { $0.appendingPathComponent("krkr2.app/Contents/MacOS/krkr2") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 检查游戏目录：散装的 `startup.tjs`（开发版 / 解包过的）直接可以；
    /// 否则打开 `data.xp3` 找 `startup.tjs`，能读出文本才算没加密。
    public static func readiness(of directory: URL) -> Readiness {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("startup.tjs").path) { return .ready }
        let xp3 = directory.appendingPathComponent("data.xp3")
        guard fm.fileExists(atPath: xp3.path) else { return .noData }
        guard let archive = try? XP3Archive(url: xp3),
              let startup = archive.entry(named: "startup.tjs"),
              let data = try? archive.read(startup)
        else { return .encrypted }
        return looksLikeScript(data) ? .ready : .encrypted
    }

    /// 解密后的 TJS 脚本是文本；加密的数据像随机字节，控制字符很多。
    /// 以 `FE FE` 开头的是吉里吉里自带的简单文本加密，krkr2 自己会解，算可读。
    static func looksLikeScript(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard !bytes.isEmpty else { return false }
        if bytes.starts(with: [0xFE, 0xFE]) { return true }
        let units: [UInt32]
        if bytes.starts(with: [0xFF, 0xFE]) {
            units = stride(from: 2, to: bytes.count - 1, by: 2).map { UInt32(bytes[$0]) | UInt32(bytes[$0 + 1]) << 8 }
        } else {
            units = bytes.map(UInt32.init)
        }
        guard !units.isEmpty else { return false }
        let control = units.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }.count
        return control * 100 <= units.count
    }

    /// krkr2 的命令行参数。存档留在游戏目录的 `savedata/`（和 Windows 版一样，互通）。
    public static func arguments(for game: Game) -> [String] {
        ["--game", game.directory.path] + game.arguments
    }
}

/// 吉里吉里的 XP3 封包，只读索引和单个文件（够判断能不能原生运行）。
///
/// 格式：11 字节标识 + 索引位置；索引可能用 zlib 压缩，可能有多段（版本 2 的封包前面多一段空的）。
/// 索引里每个 `File` 块有 `info`（文件名）和 `segm`（数据分段，每段可能单独压缩）。
struct XP3Archive {
    struct Segment: Equatable {
        var compressed: Bool
        var offset: UInt64
        var originalSize: UInt64
        var packedSize: UInt64
    }

    struct Entry: Equatable {
        var name: String
        var originalSize: UInt64
        var segments: [Segment]
    }

    enum ReadError: Error { case notXP3, truncated, badIndex, decompression }

    static let magic: [UInt8] = [0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01]
    /// 索引和单个文件的大小上限，防止坏文件让我们读进几个 G。
    static let sizeLimit: UInt64 = 64 * 1024 * 1024

    let url: URL
    let entries: [Entry]

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        func read(at offset: UInt64, count: Int) throws -> [UInt8] {
            guard offset <= fileSize, UInt64(count) <= fileSize - offset else { throw ReadError.truncated }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ReadError.truncated }
            return [UInt8](data)
        }

        guard try read(at: 0, count: 11) == Self.magic else { throw ReadError.notXP3 }
        var indexOffset = Self.u64(try read(at: 11, count: 8), 0)
        var entries: [Entry] = []
        for _ in 0..<16 {
            let head = try read(at: indexOffset, count: 9)
            let flag = head[0]
            var cursor = indexOffset + 9
            let index: [UInt8]
            switch flag & 0x07 {
            case 0: // 不压缩
                let size = Self.u64(head, 1)
                guard size <= Self.sizeLimit else { throw ReadError.badIndex }
                index = try read(at: cursor, count: Int(size))
                cursor += size
            case 1: // zlib
                let packed = Self.u64(head, 1)
                let original = Self.u64(try read(at: cursor, count: 8), 0)
                cursor += 8
                guard packed <= Self.sizeLimit, original <= Self.sizeLimit else { throw ReadError.badIndex }
                index = try Self.inflate(try read(at: cursor, count: Int(packed)), originalSize: Int(original))
                cursor += packed
            default:
                throw ReadError.badIndex
            }
            entries += try Self.parseIndex(index)
            guard flag & 0x80 != 0 else { break }
            // 还有下一段索引：紧跟在这一段后面的是它的位置。
            indexOffset = Self.u64(try read(at: cursor, count: 8), 0)
        }
        self.entries = entries
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name.lowercased() == name.lowercased() }
    }

    func read(_ entry: Entry) throws -> Data {
        guard entry.originalSize <= Self.sizeLimit else { throw ReadError.badIndex }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var out = Data()
        for segment in entry.segments {
            guard segment.packedSize <= Self.sizeLimit, segment.originalSize <= Self.sizeLimit else {
                throw ReadError.badIndex
            }
            try handle.seek(toOffset: segment.offset)
            let raw = try handle.read(upToCount: Int(segment.packedSize)) ?? Data()
            guard raw.count == Int(segment.packedSize) else { throw ReadError.truncated }
            out += segment.compressed
                ? Data(try Self.inflate([UInt8](raw), originalSize: Int(segment.originalSize)))
                : raw
        }
        return out
    }

    static func parseIndex(_ index: [UInt8]) throws -> [Entry] {
        var entries: [Entry] = []
        for (name, body) in try chunks(index[...]) where name == "File" {
            var entry = Entry(name: "", originalSize: 0, segments: [])
            for (sub, data) in try chunks(body) {
                let d = Array(data)
                switch sub {
                case "info":
                    guard d.count >= 22 else { throw ReadError.badIndex }
                    entry.originalSize = u64(d, 4)
                    let length = Int(d[20]) | Int(d[21]) << 8
                    guard d.count >= 22 + length * 2 else { throw ReadError.badIndex }
                    let units = (0..<length).map { UInt16(d[22 + $0 * 2]) | UInt16(d[23 + $0 * 2]) << 8 }
                    entry.name = String(decoding: units, as: UTF16.self)
                case "segm":
                    guard d.count % 28 == 0 else { throw ReadError.badIndex }
                    entry.segments = stride(from: 0, to: d.count, by: 28).map { i in
                        Segment(compressed: d[i] & 0x07 == 1, offset: u64(d, i + 4),
                                originalSize: u64(d, i + 12), packedSize: u64(d, i + 20))
                    }
                default:
                    break
                }
            }
            entries.append(entry)
        }
        return entries
    }

    /// 索引由 “4 字节名字 + 8 字节长度 + 内容” 的块组成。
    static func chunks(_ data: ArraySlice<UInt8>) throws -> [(String, ArraySlice<UInt8>)] {
        var result: [(String, ArraySlice<UInt8>)] = []
        var i = data.startIndex
        while i + 12 <= data.endIndex {
            let name = String(decoding: data[i..<i + 4], as: UTF8.self)
            let size = u64(Array(data[i + 4..<i + 12]), 0)
            guard size <= UInt64(data.endIndex - i - 12) else { throw ReadError.badIndex }
            let start = i + 12
            let end = start + Int(size)
            result.append((name, data[start..<end]))
            i = end
        }
        return result
    }

    static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }

    /// XP3 里是带 2 字节头的 zlib 流，Compression 框架的 ZLIB 是裸 deflate，去掉头再解。
    static func inflate(_ input: [UInt8], originalSize: Int) throws -> [UInt8] {
        guard input.count > 2, originalSize > 0 else {
            if originalSize == 0 { return [] }
            throw ReadError.decompression
        }
        var output = [UInt8](repeating: 0, count: originalSize)
        let written = input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, originalSize, src.baseAddress! + 2, src.count - 2,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == originalSize else { throw ReadError.decompression }
        return output
    }
}
