import Cocoa

/// 图标序列化工具：把任意 NSImage 真正重绘到目标尺寸再导出 PNG base64
///
/// 注意：直接 `image.size = NSSize(32,32)` 并不会缩小底层位图，TIFF 里仍保留原始的
/// 512px 表示，导出 base64 可达数百 KB（预热几百个图标就是上百 MB）。
/// 必须重绘到新 NSImage 才能真正降采样。
enum IconUtil {
    /// 列表里显示为 28px CSS，Retina 下按 64px 生成刚好清晰
    static let renderSize = NSSize(width: 64, height: 64)

    static func pngBase64(_ image: NSImage, size: NSSize = IconUtil.renderSize) -> String {
        guard let png = pngData(image, size: size) else { return "" }
        return png.base64EncodedString()
    }

    static func pngData(_ image: NSImage, size: NSSize = IconUtil.renderSize) -> Data? {
        let scaled = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
        guard let tiff = scaled.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
