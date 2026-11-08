// 生成应用图标：深色圆角方块 + 四根声波条。用法：swift tools/make_icon.swift build/AppIcon.iconset
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.20, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)])!
        .draw(in: bg, angle: -90)
    let accent = NSColor(srgbRed: 0.36, green: 0.48, blue: 0.97, alpha: 1)
    let heights: [CGFloat] = [0.20, 0.42, 0.30, 0.14]
    let barW = s * 0.085, gap = s * 0.062
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (s - total) / 2
    for h in heights {
        let bh = s * h
        let r = NSRect(x: x, y: (s - bh) / 2, width: barW, height: bh)
        accent.setFill()
        NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
