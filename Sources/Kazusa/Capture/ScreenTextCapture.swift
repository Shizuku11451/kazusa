// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import AppKit
import ScreenCaptureKit
import Vision

/// 截取屏幕上的一块区域并做 OCR。和游戏引擎无关，所以任何游戏都能用。
enum ScreenTextCapture {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case noDisplay
        case emptyRegion

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "需要“屏幕录制”权限：系统设置 → 隐私与安全性 → 屏幕与系统录音，勾选 Kazusa 后重新打开应用。"
            case .noDisplay: "截取区域不在任何显示器上"
            case .emptyRegion: "截取区域太小"
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// - Parameter rect: AppKit 全局坐标（左下角为原点）。
    @MainActor
    static func recognizeText(in rect: NSRect, languages: [String]) async throws -> String {
        guard rect.width >= 8, rect.height >= 8 else { throw CaptureError.emptyRegion }
        guard hasPermission else {
            requestPermission()
            throw CaptureError.permissionDenied
        }
        let image = try await capture(rect: rect)
        return try await recognize(image: image, languages: languages)
    }

    @MainActor
    static func capture(rect: NSRect) async throws -> CGImage {
        // AppKit 坐标 → CoreGraphics 全局坐标（左上角为原点，以主屏为基准）。
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        let cgRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.intersects(cgRect) }) else {
            throw CaptureError.noDisplay
        }
        // 把自己的窗口（悬浮窗边框、翻译文字）排除掉，只截游戏画面。
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = NSScreen.screens.first { $0.frame.intersects(rect) }?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.sourceRect = cgRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(cgRect.width * scale)
        config.height = Int(cgRect.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func recognize(image: CGImage, languages: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = languages
                request.usesLanguageCorrection = true
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let observations = request.results ?? []
                    // Vision 的坐标原点在左下角：按从上到下、从左到右排序。
                    let sorted = observations.sorted { a, b in
                        abs(a.boundingBox.midY - b.boundingBox.midY) > 0.02
                            ? a.boundingBox.midY > b.boundingBox.midY
                            : a.boundingBox.minX < b.boundingBox.minX
                    }
                    let text = sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
