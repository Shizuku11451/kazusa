// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kazusa",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kazusa", targets: ["Kazusa"]),
        .library(name: "KazusaCore", targets: ["KazusaCore"]),
    ],
    targets: [
        // 纯逻辑层：引擎识别、游戏库、Wine 运行时/前缀/启动、LLM 翻译。不依赖 UI，可单测。
        .target(name: "KazusaCore"),
        // SwiftUI 应用层：界面、屏幕截取 + OCR、翻译悬浮窗。
        .executableTarget(name: "Kazusa", dependencies: ["KazusaCore"]),
        .testTarget(name: "KazusaCoreTests", dependencies: ["KazusaCore"]),
    ]
)
