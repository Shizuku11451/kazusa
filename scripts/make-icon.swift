// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451
//
// 用代码画 Kazusa 的应用图标，输出 1024×1024 PNG。
// 用法：swift scripts/make-icon.swift <输出.png>
// 再由 scripts/make-icns.sh 生成 .icns。

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// CoreGraphics 原点在左下；下面的坐标都按“从上往下”写，用 y() 换算。
func y(_ v: CGFloat) -> CGFloat { size - v }
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}

// macOS 图标网格：824×824 的圆角方块，四周留 100。
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 阴影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(color(0x2a2350)); ctx.fillPath()
ctx.restoreGState()

// 背景：夜空靛蓝 → 暮色玫瑰
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0x1f2a6b), color(0x5b3c94), color(0xe07a9e)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: y(100)), end: CGPoint(x: 724, y: y(924)), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// 柔光
let glow = CGGradient(colorsSpace: cs, colors: [color(0xffffff, 0.28), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: y(300)), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: y(300)), endRadius: 420, options: [])

// 星星
for (sx, sy, r, a) in [(250.0, 230.0, 7.0, 0.9), (420, 180, 4, 0.7), (600, 250, 5, 0.6), (300, 400, 3.5, 0.6), (520, 360, 3, 0.5), (190, 520, 4, 0.5)] {
    ctx.setFillColor(color(0xffffff, a))
    ctx.fillEllipse(in: CGRect(x: sx - r, y: y(sy) - r, width: r * 2, height: r * 2))
}

// 对话框（galgame 的文本框）
let box = CGRect(x: 170, y: y(850), width: 684, height: 290)
let boxPath = CGPath(roundedRect: box, cornerWidth: 56, cornerHeight: 56, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x1a1033, 0.45))
ctx.addPath(boxPath); ctx.setFillColor(color(0xffffff, 0.94)); ctx.fillPath()
ctx.restoreGState()

// 名字标签
let tag = CGRect(x: 210, y: y(600), width: 230, height: 76)
ctx.addPath(CGPath(roundedRect: tag, cornerWidth: 38, cornerHeight: 38, transform: nil))
let tagGrad = CGGradient(colorsSpace: cs, colors: [color(0x6b4fd0), color(0xd96a9a)] as CFArray, locations: [0, 1])!
ctx.saveGState(); ctx.clip()
ctx.drawLinearGradient(tagGrad, start: CGPoint(x: tag.minX, y: tag.midY), end: CGPoint(x: tag.maxX, y: tag.midY), options: [])
ctx.restoreGState()
// 标签上的小点（代替文字）
for i in 0..<3 {
    ctx.setFillColor(color(0xffffff, 0.95))
    ctx.fillEllipse(in: CGRect(x: 262 + CGFloat(i) * 46, y: y(562) - 12, width: 24, height: 24))
}

// 文本行
let lines: [(CGFloat, CGFloat)] = [(650, 500), (712, 564), (774, 360)]
for (ly, w) in lines {
    let r = CGRect(x: 230, y: y(ly) - 15, width: w, height: 30)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.setFillColor(color(0x3b3170, 0.82)); ctx.fillPath()
}
// “下一句”三角
ctx.beginPath()
ctx.move(to: CGPoint(x: 770, y: y(756)))
ctx.addLine(to: CGPoint(x: 810, y: y(756)))
ctx.addLine(to: CGPoint(x: 790, y: y(790)))
ctx.closePath()
ctx.setFillColor(color(0xd96a9a)); ctx.fillPath()

// 樱花
func petal(center: CGPoint, radius: CGFloat, rotation: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: rotation)
    for i in 0..<5 {
        ctx.saveGState()
        ctx.rotate(by: CGFloat(i) * 2 * .pi / 5)
        let p = CGMutablePath()
        p.move(to: .zero)
        p.addCurve(to: CGPoint(x: -radius * 0.12, y: radius),
                   control1: CGPoint(x: -radius * 0.55, y: radius * 0.35),
                   control2: CGPoint(x: -radius * 0.5, y: radius * 0.9))
        p.addQuadCurve(to: CGPoint(x: 0, y: radius * 0.88), control: CGPoint(x: -radius * 0.06, y: radius * 0.97)) // 花瓣尖端的缺口
        p.addQuadCurve(to: CGPoint(x: radius * 0.12, y: radius), control: CGPoint(x: radius * 0.06, y: radius * 0.97))
        p.addCurve(to: .zero,
                   control1: CGPoint(x: radius * 0.5, y: radius * 0.9),
                   control2: CGPoint(x: radius * 0.55, y: radius * 0.35))
        ctx.addPath(p)
        ctx.restoreGState()
    }
    let g = CGGradient(colorsSpace: cs, colors: [color(0xffffff), color(0xffc7dc)] as CFArray, locations: [0, 1])!
    ctx.clip()
    ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    ctx.restoreGState()
    // 花心
    ctx.setFillColor(color(0xe0558a))
    ctx.fillEllipse(in: CGRect(x: center.x - radius * 0.1, y: center.y - radius * 0.1, width: radius * 0.2, height: radius * 0.2))
}
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x40164a, 0.35))
petal(center: CGPoint(x: 700, y: y(330)), radius: 150, rotation: 0.25)
ctx.restoreGState()
petal(center: CGPoint(x: 520, y: y(470)), radius: 52, rotation: -0.4)

ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
