import Cocoa

/// 品牌图标：可爱小黄鸭
/// 同一套绘制代码同时用于菜单栏图标、App 图标（构建期由 tools/make_app_icon.swift 复用）
enum DuckIcon {

    // MARK: - 菜单栏图标

    /// 菜单栏图标：小黄鸭 + 可选的 "ya" 字样
    /// - Parameter showText: 是否显示品牌文字（默认显示）
    static func menuBarImage(height: CGFloat = 20, showText: Bool = true) -> NSImage {
        let duckW = height * 0.95
        var width = duckW
        var titleWidth: CGFloat = 0
        let font = NSFont.boldSystemFont(ofSize: height * 0.72)

        if showText {
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            titleWidth = ("ya" as NSString).size(withAttributes: attrs).width
            width = duckW + 4 + titleWidth
        }

        let image = NSImage(size: NSSize(width: ceil(width), height: height))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            flip(ctx, height: height)
            drawDuck(ctx: ctx, in: CGRect(x: 0, y: (height - duckW) / 2, width: duckW, height: duckW))
            if showText {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
                ("ya" as NSString).draw(
                    at: NSPoint(x: duckW + 4, y: (height - font.capHeight) / 2 - 1),
                    withAttributes: attrs
                )
            }
        }
        image.unlockFocus()
        image.isTemplate = false // 保留彩色小黄鸭
        return image
    }

    // MARK: - App 图标

    /// App 图标：圆角方形渐变底 + 小黄鸭
    static func appIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            flip(ctx, height: size)
            drawAppIcon(ctx: ctx, size: size)
        }
        image.unlockFocus()
        return image
    }

    /// 直接绘制 App 图标（构建期生成 PNG 用）
    static func drawAppIcon(ctx: CGContext, size: CGFloat) {
        // 圆角方形底（macOS 风格：约 22% 圆角）
        let radius = size * 0.2237
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // 水蓝渐变背景，衬托黄鸭
        let colors = [NSColor(hex: 0x8FD8FF).cgColor, NSColor(hex: 0x3E9DEB).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: size),
                                   options: [])
        }
        // 底部水面（深蓝波纹）
        ctx.setFillColor(NSColor(hex: 0x2E86D9, alpha: 0.85).cgColor)
        let wave = CGMutablePath()
        wave.move(to: CGPoint(x: 0, y: size * 0.80))
        wave.addCurve(to: CGPoint(x: size, y: size * 0.84),
                      control1: CGPoint(x: size * 0.3, y: size * 0.74),
                      control2: CGPoint(x: size * 0.7, y: size * 0.90))
        wave.addLine(to: CGPoint(x: size, y: size))
        wave.addLine(to: CGPoint(x: 0, y: size))
        wave.closeSubpath()
        ctx.addPath(wave)
        ctx.fillPath()
        // 水面高光
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(size * 0.015)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: size * 0.12, y: size * 0.83))
        ctx.addQuadCurve(to: CGPoint(x: size * 0.38, y: size * 0.81),
                         control: CGPoint(x: size * 0.25, y: size * 0.79))
        ctx.strokePath()
        ctx.restoreGState()

        // 鸭子居中，占 74%
        let duckSize = size * 0.74
        drawDuck(ctx: ctx, in: CGRect(x: (size - duckSize) / 2,
                                      y: (size - duckSize) / 2 - size * 0.02,
                                      width: duckSize,
                                      height: duckSize))
    }

    // MARK: - 鸭子本体

    /// 在给定 rect 内绘制小黄鸭（坐标系：y 向下，rect.origin 为左上角）
    static func drawDuck(ctx: CGContext, in rect: CGRect) {
        let s = min(rect.width, rect.height)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - s / 2, y: rect.midY - s / 2)
        ctx.scaleBy(x: s, y: s)
        // 以下坐标均为 0...1，y 向下

        let body = NSColor(hex: 0xFFD84D)      // 身体/头：明亮黄
        let shade = NSColor(hex: 0xF5B324)     // 翅膀/尾巴：深一点的黄
        let beak = NSColor(hex: 0xFF9F1A)      // 喙：橙
        let eye = NSColor(hex: 0x3B3226)       // 眼睛：深褐

        // 尾巴（从身体左上方翘起）
        ctx.setFillColor(shade.cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0.22, y: 0.44))
        ctx.addQuadCurve(to: CGPoint(x: 0.02, y: 0.10), control: CGPoint(x: 0.02, y: 0.32))
        ctx.addQuadCurve(to: CGPoint(x: 0.36, y: 0.46), control: CGPoint(x: 0.14, y: 0.20))
        ctx.closePath()
        ctx.fillPath()

        // 身体
        ctx.setFillColor(body.cgColor)
        ctx.fillEllipse(in: CGRect(x: 0.03, y: 0.33, width: 0.63, height: 0.52))

        // 翅膀
        ctx.setFillColor(shade.withAlphaComponent(0.85).cgColor)
        ctx.saveGState()
        ctx.translateBy(x: 0.30, y: 0.60)
        ctx.rotate(by: -0.22)
        ctx.fillEllipse(in: CGRect(x: -0.17, y: -0.10, width: 0.34, height: 0.20))
        ctx.restoreGState()

        // 头
        ctx.setFillColor(body.cgColor)
        ctx.fillEllipse(in: CGRect(x: 0.50, y: 0.05, width: 0.45, height: 0.45))

        // 腮红
        ctx.setFillColor(NSColor(hex: 0xFF8FA3).withAlphaComponent(0.55).cgColor)
        ctx.fillEllipse(in: CGRect(x: 0.585, y: 0.315, width: 0.10, height: 0.065))

        // 喙
        ctx.setFillColor(beak.cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0.875, y: 0.225))
        ctx.addQuadCurve(to: CGPoint(x: 1.00, y: 0.305), control: CGPoint(x: 0.965, y: 0.245))
        ctx.addQuadCurve(to: CGPoint(x: 0.870, y: 0.395), control: CGPoint(x: 0.965, y: 0.365))
        ctx.closePath()
        ctx.fillPath()
        // 喙的中线
        ctx.setStrokeColor(NSColor(hex: 0xE07B0A).cgColor)
        ctx.setLineWidth(0.012)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0.885, y: 0.308))
        ctx.addLine(to: CGPoint(x: 0.985, y: 0.305))
        ctx.strokePath()

        // 眼睛
        ctx.setFillColor(eye.cgColor)
        ctx.fillEllipse(in: CGRect(x: 0.735, y: 0.185, width: 0.085, height: 0.095))
        // 高光
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        ctx.fillEllipse(in: CGRect(x: 0.762, y: 0.205, width: 0.032, height: 0.034))

        ctx.restoreGState()
    }

    // MARK: - 辅助

    /// 把 CGContext 翻成 UIKit 风格（原点左上、y 向下），方便按视觉坐标绘制
    private static func flip(_ ctx: CGContext, height: CGFloat) {
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
