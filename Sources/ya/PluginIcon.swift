import Cocoa

/// 插件图标：32px PNG base64
/// 优先级：plugin.json 的 `icon` 字段（图片文件名 或 emoji）→ 关键字首字母生成的字母图标
/// 生成过程放在后台队列，与 AppSearcher 一样不阻塞主线程
enum PluginIcon {
    private static var cache: [String: String] = [:]
    private static var pending: Set<String> = []
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "com.ya.pluginIcon", qos: .userInitiated)

    static func cached(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    /// 异步取图标：命中缓存立即回调；否则后台绘制后回主线程回调
    static func request(id: String, entry: PluginIndex.Entry?, completion: @escaping (String) -> Void) {
        if let c = cached(id: id) {
            completion(c)
            return
        }
        lock.lock()
        let alreadyPending = pending.contains(id)
        if !alreadyPending { pending.insert(id) }
        lock.unlock()
        guard !alreadyPending else { return }

        queue.async {
            let image = make(id: id, entry: entry)
            let b64 = IconUtil.pngBase64(image)
            lock.lock()
            cache[id] = b64
            pending.remove(id)
            lock.unlock()
            DispatchQueue.main.async { completion(b64) }
        }
    }

    /// 插件图标变更后清缓存（重新加载插件系统时调用）
    static func invalidate() {
        lock.lock()
        cache.removeAll()
        pending.removeAll()
        lock.unlock()
    }

    // MARK: - 绘制

    static func make(id: String, entry: PluginIndex.Entry?) -> NSImage {
        let size = IconUtil.renderSize
        let declaredIcon = entry?.manifest["icon"] as? String

        // 1) 插件自带的图片文件
        if let name = declaredIcon,
           let dir = PluginLoader.directory(of: id),
           let image = loadImage(at: dir.appendingPathComponent(name)) {
            return resized(image, to: size)
        }
        // 2) emoji / 短文本图标
        if let glyph = declaredIcon, isGlyphIcon(glyph) {
            return glyphImage(glyph, size: size, hue: hue(of: id))
        }
        // 3) 兜底：关键字/名称首字母
        let seed = entry?.activateKeyword ?? entry?.nameText ?? id
        let letter = String(seed.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "#")
        return glyphImage(letter.uppercased(), size: size, hue: hue(of: id), fontSize: size.width * 0.56)
    }

    private static func loadImage(at url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOfFile: url.path)
    }

    /// 不含扩展名且字符数很少 → 当作 emoji / 字形直接绘制
    private static func isGlyphIcon(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4 else { return false }
        return !trimmed.contains(".")
    }

    private static func glyphImage(_ glyph: String,
                                   size: NSSize,
                                   hue: CGFloat,
                                   fontSize: CGFloat? = nil) -> NSImage {
        let radius = size.width * 0.22
        let inset = size.width * 0.03
        let font = fontSize ?? size.width * 0.62
        return NSImage(size: size, flipped: false) { rect in
            let bg = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                  xRadius: radius, yRadius: radius)
            NSColor(calibratedHue: hue, saturation: 0.45, brightness: 0.92, alpha: 1).setFill()
            bg.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: font),
                .foregroundColor: NSColor.white,
                .paragraphStyle: centeredStyle()
            ]
            let text = glyph as NSString
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
            return true
        }
    }

    private static func centeredStyle() -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.alignment = .center
        return s
    }

    private static func resized(_ image: NSImage, to size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
    }

    /// 由 id 派生稳定色相，同一插件每次颜色一致
    private static func hue(of id: String) -> CGFloat {
        var hash: UInt64 = 5381
        for b in id.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return CGFloat(hash % 360) / 360.0
    }

}
