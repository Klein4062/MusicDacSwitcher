// gen-icon.swift — 生成应用图标（渐变 squircle + 白色声波柱）
// 用法: swift scripts/gen-icon.swift <输出iconset目录>

import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // squircle 背景：深蓝 → 紫 渐变
    let radius = size * 0.235
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.92, alpha: 1),
    ])!.draw(in: rect, angle: 38)

    // 顶部柔和高光
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.14),
        NSColor.white.withAlphaComponent(0.0),
    ])!.draw(in: NSRect(x: 0, y: size * 0.55, width: size, height: size * 0.45), angle: 90)

    // 中央声波柱（音波高低起伏）
    let bars: [CGFloat] = [0.24, 0.38, 0.56, 0.76, 0.98, 0.76, 0.56, 0.38, 0.24]
    let n = bars.count
    let barW = size * 0.046
    let gap = size * 0.030
    let total = CGFloat(n) * barW + CGFloat(n - 1) * gap
    var x = (size - total) / 2
    let cy = size / 2
    for h in bars {
        let bh = size * 0.54 * h
        let r = NSRect(x: x, y: cy - bh / 2, width: barW, height: bh)
        NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    return img
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, s) in sizes {
    let img = draw(size: s)
    NSColor.white.set()
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        continue
    }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("iconset → \(outDir)")
