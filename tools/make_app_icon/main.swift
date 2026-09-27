import Cocoa

// 构建期工具：用 DuckIcon 生成 AppIcon.iconset（随后由 iconutil 合成 .icns）
// 用法：ya-makeicon <iconset 目录>

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: ya-makeicon <iconset-dir>\n", stderr)
    exit(2)
}
let iconset = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (文件名, 像素尺寸)
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func png(size px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    // 翻成 y 向下坐标系（与 DuckIcon 的绘制约定一致）
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)
    DuckIcon.drawAppIcon(ctx: ctx, size: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

for (name, px) in specs {
    guard let data = png(size: px) else {
        fputs("failed: \(name)\n", stderr)
        exit(1)
    }
    do {
        try data.write(to: iconset.appendingPathComponent(name))
    } catch {
        fputs("write failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

print("iconset generated at \(iconset.path)")
