#!/usr/bin/env swift
// Pulse 应用图标渲染脚本:纯 CoreGraphics,零第三方依赖,图标可重现、可调参。
//
// 用法:
//   swift scripts/render-app-icon.swift Pulse/Assets.xcassets/AppIcon.appiconset [--preview <预览图.png>]
//
// 输出经典 macOS 十档 appiconset(16…512 @1x/@2x)+ Contents.json。每档按目标像素
// 原生绘制(不是 1024 缩放):小尺寸线条加粗、省略细节,保证 16/32px 下仍能认出脉搏线。
// 画的是全出血方形——macOS 26 会自己套连续圆角与玻璃层,这里不预画圆角
// (预画会被系统二次裁成"框里套框")。
// 设计语言对齐 DESIGN.md:深色 surface 底 + 指标色(CPU 蓝 → 内存紫)心电脉搏线。

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct IconRenderer {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // 令牌(DESIGN.md 深色值):底色取 surface 两档上下各推一点拉开层次,脉搏线取两枚指标色
    let surfaceTop: UInt32 = 0x2A2A2E      // surface-card-high 深色 #27272b 略提亮
    let surfaceBottom: UInt32 = 0x121214   // surface-window 深色 #1a1a1d 略压暗
    let cpuBlue: UInt32 = 0x3987E5         // accent-cpu 深色
    let memoryViolet: UInt32 = 0x9085E9    // accent-memory 深色

    // 1024 基准坐标(CoreGraphics 原点在左下)
    enum Geometry {
        static let lineStart: CGFloat = 150
        static let lineEnd: CGFloat = 874
        static let baseline: CGFloat = 482   // 尖峰高于深谷,基线下压 30 让整体视觉居中
    }

    struct Slot {
        let points: Int
        let scale: Int
        var pixels: Int { points * scale }
        var filename: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
    }

    let slots: [Slot] = [16, 32, 128, 256, 512].flatMap {
        [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)]
    }

    func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: srgb, components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ])!
    }

    func gradient(_ stops: [(hex: UInt32, alpha: CGFloat)]) -> CGGradient {
        let colors = stops.map { color($0.hex, alpha: $0.alpha) }
        return CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: nil)!
    }

    func circle(_ center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// 心电折线:平 → 小波 → 大尖峰 → 深谷 → 平,终点落在"实时"圆点中心。
    /// 小尺寸去掉小波并把尖峰拉宽,否则在 16px 下糊成一团。
    func pulsePath(scale s: CGFloat, compact: Bool) -> CGPath {
        func pt(_ t: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(x: (Geometry.lineStart + t * (Geometry.lineEnd - Geometry.lineStart)) * s,
                    y: (Geometry.baseline + dy) * s)
        }
        let path = CGMutablePath()
        path.move(to: pt(0, 0))
        if compact {
            path.addLine(to: pt(0.34, 0))
            path.addLine(to: pt(0.47, 300))
            path.addLine(to: pt(0.60, -240))
            path.addLine(to: pt(0.70, 0))
        } else {
            path.addLine(to: pt(0.22, 0))
            path.addLine(to: pt(0.27, 48))
            path.addLine(to: pt(0.32, 0))
            path.addLine(to: pt(0.41, 0))
            path.addLine(to: pt(0.49, 300))
            path.addLine(to: pt(0.58, -240))
            path.addLine(to: pt(0.65, 0))
        }
        path.addLine(to: pt(1, 0))
        return path
    }

    /// 在 size×size 位图上画完整图标。
    func draw(in ctx: CGContext, size: CGFloat) {
        let s = size / 1024
        let tiny = size <= 32    // 16/32:只留主脉冲
        let small = size < 128   // <128:不画网格、线更粗

        // 底:深色 surface 竖向渐变 + 中心偏上的 CPU 蓝光晕
        ctx.drawLinearGradient(gradient([(surfaceTop, 1), (surfaceBottom, 1)]),
                               start: CGPoint(x: 0, y: size), end: .zero, options: [])
        let glowCenter = CGPoint(x: 512 * s, y: 540 * s)
        ctx.drawRadialGradient(gradient([(cpuBlue, 0.30), (cpuBlue, 0)]),
                               startCenter: glowCenter, startRadius: 0,
                               endCenter: glowCenter, endRadius: 600 * s, options: [])

        // 网格:呼应 AreaTrendChartView 的 8% 网格线,只在大尺寸可见
        if !small {
            ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.06))
            ctx.setLineWidth(max(1, 3 * s))
            for y in stride(from: 212, through: 812, by: 150) {
                ctx.move(to: CGPoint(x: 0, y: CGFloat(y) * s))
                ctx.addLine(to: CGPoint(x: size, y: CGFloat(y) * s))
            }
            ctx.strokePath()
        }

        // 把折线转成描边形状,后面既做光晕又做渐变填充
        ctx.saveGState()
        ctx.addPath(pulsePath(scale: s, compact: tiny))
        ctx.setLineWidth((small ? 100 : 72) * s)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        let shape = ctx.path!
        ctx.restoreGState()
        ctx.beginPath()

        // 光晕:同形状加大模糊投影
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 60 * s, color: color(cpuBlue, alpha: 0.55))
        ctx.addPath(shape)
        ctx.setFillColor(color(cpuBlue))
        ctx.fillPath()
        ctx.restoreGState()

        // 线本体:CPU 蓝 → 内存紫 横向渐变
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(cpuBlue, 1), (memoryViolet, 1)]),
                               start: CGPoint(x: Geometry.lineStart * s, y: 0),
                               end: CGPoint(x: Geometry.lineEnd * s, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()

        // 末端"实时"圆点:紫色 + 柔光环
        let dotCenter = CGPoint(x: Geometry.lineEnd * s, y: Geometry.baseline * s)
        if !tiny {
            ctx.setFillColor(color(memoryViolet, alpha: 0.18))
            ctx.fillEllipse(in: circle(dotCenter, radius: 100 * s))
        }
        ctx.setFillColor(color(memoryViolet))
        ctx.fillEllipse(in: circle(dotCenter, radius: (tiny ? 68 : 54) * s))
    }

    func image(size pixels: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        draw(in: ctx, size: CGFloat(pixels))
        return ctx.makeImage()!
    }

    func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            fail("无法创建 \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { fail("写入失败 \(url.path)") }
    }

    func writeAppIconSet(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rendered: [Int: CGImage] = [:]
        var images: [[String: Any]] = []
        for slot in slots {
            let img = rendered[slot.pixels] ?? image(size: slot.pixels)
            rendered[slot.pixels] = img
            writePNG(img, to: dir.appendingPathComponent(slot.filename))
            images.append([
                "filename": slot.filename,
                "idiom": "mac",
                "scale": "\(slot.scale)x",
                "size": "\(slot.points)x\(slot.points)",
            ])
        }
        let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("Contents.json"))
    }

    /// 预览板:左浅右深两块底,各放 256/128/64/32/16 五档,套近似 macOS 圆角遮罩(仅预览用)。
    func preview() -> CGImage {
        let sizes = [256, 128, 64, 32, 16]
        let pad: CGFloat = 64, gap: CGFloat = 48
        let halfWidth = pad * 2 + sizes.reduce(0) { $0 + CGFloat($1) } + gap * CGFloat(sizes.count - 1)
        let height = 256 + pad * 2
        let ctx = CGContext(data: nil, width: Int(halfWidth * 2), height: Int(height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        let backgrounds: [UInt32] = [0xF5F5F7, 0x1A1A1D]  // surface-card 浅 / surface-window 深
        for (half, background) in backgrounds.enumerated() {
            let originX = CGFloat(half) * halfWidth
            ctx.setFillColor(color(background))
            ctx.fill(CGRect(x: originX, y: 0, width: halfWidth, height: height))
            var x = originX + pad
            for size in sizes {
                let side = CGFloat(size)
                let rect = CGRect(x: x, y: (height - side) / 2, width: side, height: side)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: side * 0.2237, cornerHeight: side * 0.2237,
                                   transform: nil))
                ctx.clip()
                ctx.draw(image(size: size), in: rect)
                ctx.restoreGState()
                x += side + gap
            }
        }
        return ctx.makeImage()!
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let outputPath = arguments.first, !outputPath.hasPrefix("--") else {
    fail("用法: swift scripts/render-app-icon.swift <AppIcon.appiconset 目录> [--preview <预览.png>]")
}

let renderer = IconRenderer()
do {
    try renderer.writeAppIconSet(to: URL(fileURLWithPath: outputPath))
    print("已写入 \(renderer.slots.count) 档图标 → \(outputPath)")
    if let flag = arguments.firstIndex(of: "--preview"), flag + 1 < arguments.count {
        let previewURL = URL(fileURLWithPath: arguments[flag + 1])
        renderer.writePNG(renderer.preview(), to: previewURL)
        print("预览 → \(previewURL.path)")
    }
} catch {
    fail("失败: \(error)")
}
