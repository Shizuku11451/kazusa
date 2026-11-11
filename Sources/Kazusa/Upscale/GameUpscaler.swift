// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import AppKit
import CoreMedia
import MetalFX
import ScreenCaptureKit

/// 实时画面放大：用 ScreenCaptureKit 抓游戏窗口的原始像素（1 倍），MetalFX 放大到屏幕的实际像素，
/// 盖在游戏窗口正上方。点击穿透到下面的游戏，坐标一一对应，不用做鼠标换算。
///
/// 全程在 GPU 上：IOSurface → MTLTexture 零拷贝，画面没变（SCK 报 idle）的帧直接跳过。
@MainActor
final class GameUpscaler: NSObject, SCStreamDelegate {
    enum UpscaleError: LocalizedError {
        case noGameWindow, noMetal

        var errorDescription: String? {
            switch self {
            case .noGameWindow: "没找到游戏窗口：先点一下游戏窗口，让它在最前面，再按 \(GlobalHotKeys.Combo.upscale.display)。"
            case .noMetal: "这台 Mac 不支持 MetalFX。"
            }
        }
    }

    private var panel: NSPanel?
    private var stream: SCStream?
    private var renderer: UpscaleRenderer?
    private var tracker: GameWindowTracker?
    private var activationObserver: NSObjectProtocol?

    func toggle() async throws {
        if panel != nil { stop() } else { try await start() }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        tracker?.stop()
        tracker = nil
        activationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        activationObserver = nil
        panel?.orderOut(nil)
        panel = nil
        renderer = nil
    }

    /// 放大最前面那个应用（游戏）的主窗口。
    private func start() async throws {
        guard ScreenTextCapture.hasPermission else {
            ScreenTextCapture.requestPermission()
            throw ScreenTextCapture.CaptureError.permissionDenied
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier
        else { throw UpscaleError.noGameWindow }
        // 和 GameWindowTracker 挑同一个窗口：普通层级里最大的那个。
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows
            .filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 200 && $0.frame.height >= 150 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { throw UpscaleError.noGameWindow }
        guard let renderer = UpscaleRenderer(device: MTLCreateSystemDefaultDevice()) else { throw UpscaleError.noMetal }

        let frame = GameWindowTracker.appKitRect(window.frame)
        let panel = makePanel(frame: frame, layer: renderer.layer)
        resize(renderer.layer, in: panel)

        let config = Self.configuration(size: window.frame.size, panel: panel)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try stream.addStreamOutput(renderer, type: .screen, sampleHandlerQueue: renderer.queue)
        try await stream.startCapture()

        self.panel = panel
        self.renderer = renderer
        self.stream = stream
        panel.orderFrontRegardless()

        // 游戏挪动、改大小：跟着挪，抓取分辨率跟着改。
        let tracker = GameWindowTracker(executable: nil, pid: pid) { [weak self] _, new in
            self?.follow(new)
        }
        tracker.start()
        self.tracker = tracker
        // 切到别的应用时藏起来，切回游戏再显示（面板层级比普通窗口高）。
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let active = app?.processIdentifier
            MainActor.assumeIsolated {
                if active == pid { self?.panel?.orderFrontRegardless() }
                else if active != ProcessInfo.processInfo.processIdentifier { self?.panel?.orderOut(nil) }
            }
        }
    }

    private func follow(_ frame: NSRect) {
        guard let panel, let renderer, let stream else { return }
        let resized = panel.frame.size != frame.size
        panel.setFrame(frame, display: false)
        guard resized else { return }
        resize(renderer.layer, in: panel)
        stream.updateConfiguration(Self.configuration(size: frame.size, panel: panel)) { _ in }
    }

    /// 按窗口的点数抓（1 倍像素）：Wine 默认不开 Retina，游戏画面的原始像素就是这么大。
    private static func configuration(size: CGSize, panel: NSPanel) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(panel.screen?.maximumFramesPerSecond ?? 60))
        return config
    }

    private func resize(_ layer: CAMetalLayer, in panel: NSPanel) {
        let scale = panel.backingScaleFactor
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: panel.frame.width * scale, height: panel.frame.height * scale)
    }

    private func makePanel(frame: NSRect, layer: CAMetalLayer) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // 比普通窗口高、比翻译字幕条（.floating）低。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer = layer
        panel.contentView = view
        return panel
    }

    // 游戏退出、窗口关掉时 SCK 会停掉流。
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.stop() }
    }
}

/// 在 SCK 的回调队列上把每一帧放大后画出来。只在这个队列上用，所以标成 @unchecked Sendable。
private final class UpscaleRenderer: NSObject, SCStreamOutput, @unchecked Sendable {
    let layer = CAMetalLayer()
    let queue = DispatchQueue(label: "kazusa.upscale", qos: .userInteractive)
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private var scaler: MTLFXSpatialScaler?
    private var output: MTLTexture?

    init?(device: MTLDevice?) {
        guard let device,
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let commandQueue = device.makeCommandQueue()
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.commandQueue = commandQueue
        textureCache = cache
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = false // 要往 drawable 里 blit
        layer.maximumDrawableCount = 2 // 少排一帧，延迟低
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // 只处理画面真的变了的帧；静止画面（.idle）不占 GPU。
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer
        else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixels, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture, let input = CVMetalTextureGetTexture(cvTexture),
              let drawable = layer.nextDrawable(),
              let scaler = scaler(input: input, output: drawable.texture),
              let output,
              let commands = commandQueue.makeCommandBuffer()
        else { return }

        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.inputContentWidth = width
        scaler.inputContentHeight = height
        scaler.encode(commandBuffer: commands)
        if let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: output, to: drawable.texture)
            blit.endEncoding()
        }
        commands.present(drawable)
        nonisolated(unsafe) let keepAlive = cvTexture
        commands.addCompletedHandler { _ in _ = keepAlive } // GPU 用完前别让 IOSurface 被回收
        commands.commit()
    }

    /// 输入或输出尺寸变了才重建（MetalFX 的 scaler 绑定固定尺寸）。
    private func scaler(input: MTLTexture, output target: MTLTexture) -> MTLFXSpatialScaler? {
        if let scaler, scaler.inputWidth == input.width, scaler.inputHeight == input.height,
           scaler.outputWidth == target.width, scaler.outputHeight == target.height {
            return scaler
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = input.width
        descriptor.inputHeight = input.height
        descriptor.outputWidth = target.width
        descriptor.outputHeight = target.height
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let device = layer.device, let scaler = descriptor.makeSpatialScaler(device: device) else { return nil }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: target.width, height: target.height, mipmapped: false
        )
        textureDescriptor.usage = scaler.outputTextureUsage
        textureDescriptor.storageMode = .private
        output = device.makeTexture(descriptor: textureDescriptor)
        self.scaler = scaler
        return scaler
    }
}
