import Cocoa

/// 轮询系统剪贴板，保存文本 / 图片 / 文件的历史，支持收藏与数量上限。
///
/// 分层：`ClipboardStore` 只管条目怎么排 / 去重 / 裁剪（纯数据，有单测覆盖）；
/// 本类负责三件带副作用的事 —— 轮询 NSPasteboard、生成缩略图、读写磁盘。
///
/// 持久化：`~/Library/Application Support/ya/clipboard.json`（元数据），
/// 图片缩略图落在同级的 `clipboard-images/<id>.png`。
/// 图片只存降采样后的 PNG，避免把原图全塞进内存。
final class ClipboardManager {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var store = ClipboardStore()
    /// 缩略图最长边（px）：列表里只需要看清轮廓，存原图没必要
    private static let thumbMax = 480

    /// 插件/前端读取的历史（收藏在前，其余按时间倒序）
    var items: [ClipItem] { store.items }

    private var imageDir: URL { AppPaths.clipboardImages }
    private var storeURL: URL { AppPaths.file("clipboard.json") }
    private var limit: Int { AppSettings.shared.clipboardLimit }

    init() {
        load()
    }

    func start() {
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.poll() }
        // common mode：菜单展开/拖拽等 tracking 期间也能继续轮询
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        trim() // 启动即按当前上限裁剪（上次运行可能用了更大的上限）
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit { stop() }

    /// 插件主动写剪贴板（`api.copyText`）：也要进历史，否则用户刚复制的东西自己看不见
    func copyTextForPlugin(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        insertText(text)
    }

    // MARK: - 轮询

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // 优先级：文件 > 图片 > 文本。复制一张图时系统往往同时放了文本，别把图吞掉
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty, urls.allSatisfy({ $0.isFileURL }) {
            insertFileItem(urls.map(\.path))
            return
        }
        if let image = NSImage(pasteboard: pb) {
            insertImage(image)
            return
        }
        if let str = pb.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertText(str)
        }
    }

    private func insertText(_ text: String) {
        // 去重：把旧的同内容条目挤掉，避免反复复制同一段占满历史
        let (_, evicted) = store.insert(
            ClipItem(id: UUID().uuidString, kind: .text, text: text, paths: [],
                     timestamp: Date().timeIntervalSince1970, pinned: false, hasImage: false),
            limit: limit
        )
        evicted.forEach { self.deleteThumbnail(id: $0) }
        save()
    }

    private func insertFileItem(_ paths: [String]) {
        let (_, evicted) = store.insert(
            ClipItem(id: UUID().uuidString, kind: .file, text: paths.joined(separator: "\n"),
                     paths: paths, timestamp: Date().timeIntervalSince1970, pinned: false,
                     hasImage: paths.count == 1 && Self.isImagePath(paths[0])),
            limit: limit
        )
        evicted.forEach { self.deleteThumbnail(id: $0) }
        save()
    }

    /// 图片：先把缩略图落到磁盘（后台），再把条目插到最前。
    /// 编码放到后台队列：主 RunLoop 上做大图 PNG 编码会卡住输入。
    /// 图片**不去重**（ClipboardStore.append）：条目 text 恒为空串，
    /// 一去重连续截两张图就只剩最后一张。
    private func insertImage(_ image: NSImage) {
        let id = UUID().uuidString
        let file = imageDir.appendingPathComponent("\(id).png")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard Self.writeThumbnail(of: image, to: file) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let evicted = self.store.append(
                    ClipItem(id: id, kind: .image, text: "", paths: [],
                             timestamp: Date().timeIntervalSince1970, pinned: false, hasImage: true),
                    limit: self.limit
                )
                evicted.forEach { self.deleteThumbnail(id: $0) }
                self.save()
            }
        }
    }

    // MARK: - 对外操作

    /// 把某条历史写回系统剪贴板（前端 Enter 复制用）
    @discardableResult
    func restore(id: String) -> Bool {
        guard let item = store.item(id: id) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text, forType: .string)
        case .file:
            pb.writeObjects(item.paths.compactMap { URL(string: "file://\($0)") } as [NSURL])
            pb.setString(item.text, forType: .string)
        case .image:
            let file = imageDir.appendingPathComponent("\(item.id).png")
            if let image = NSImage(contentsOf: file) { pb.writeObjects([image]) }
        }
        lastChangeCount = pb.changeCount
        return true
    }

    func togglePin(id: String) {
        guard store.togglePin(id: id) else { return }
        save()
    }

    func remove(id: String) {
        guard let removed = store.remove(id: id) else { return }
        deleteThumbnail(id: removed)
        save()
    }

    /// 清空历史；默认保留收藏项
    func clear(keepingPinned: Bool = true) {
        store.clear(keepingPinned: keepingPinned).forEach { self.deleteThumbnail(id: $0) }
        save()
    }

    /// 图片缩略图的 data URL（给 WebView 直接当 img src）
    /// 图片文件的缩略图按需生成：复制文件时剪贴板里没有位图，只能现读原图。
    func imageDataURL(id: String) -> String {
        let file = imageDir.appendingPathComponent("\(id).png")
        if !FileManager.default.fileExists(atPath: file.path) {
            // 还没生成过：只有单张图片文件的条目才现生成
            guard let item = store.item(id: id),
                  item.kind == .file,
                  item.paths.count == 1,
                  Self.isImagePath(item.paths[0]),
                  let image = NSImage(contentsOfFile: item.paths[0]) else { return "" }
            _ = Self.writeThumbnail(of: image, to: file)
        }
        guard let data = FileManager.default.contents(atPath: file.path) else { return "" }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    // MARK: - 持久化

    private func save() {
        // SafeJSON：历史里是用户复制的任意文本，JSONSerialization 对特殊字符串会抛
        // ObjC 异常（try? 挡不住）→ 直接闪退。见 SafeJSON 注释。
        guard let data = store.encode() else { return }
        let url = storeURL // 主线程取好路径，后台只做写文件
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: storeURL.path) else { return }
        // 磁盘上的图片可能已被手工清理，顺手纠正 hasImage
        let onDisk = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: imageDir.path))?
                .map { ($0 as NSString).deletingPathExtension } ?? []
        )
        store.replaceAll(ClipboardStore.decode(data: data), existingImageIDs: onDisk)
    }

    /// 按当前上限裁剪（启动时调用：上次运行可能用了更大的上限）
    private func trim() {
        store.trim(limit: limit).forEach { self.deleteThumbnail(id: $0) }
        trimImagesOnDisk()
    }

    /// 磁盘上的缩略图最多留 120 张，按修改时间删最旧的
    private func trimImagesOnDisk() {
        let fm = FileManager.default
        let maxCount = 120
        guard let files = try? fm.contentsOfDirectory(
            at: imageDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ), files.count > maxCount else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return da < db
        }
        for file in sorted.prefix(files.count - maxCount) { try? fm.removeItem(at: file) }
    }

    private func deleteThumbnail(id: String) {
        try? FileManager.default.removeItem(
            at: imageDir.appendingPathComponent("\(id).png")
        )
    }

    // MARK: - 图片工具

    private static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"].contains(ext)
    }

    /// 降采样后写 PNG。历史里不需要原图尺寸，存原图会让磁盘和内存都爆。
    private static func writeThumbnail(of image: NSImage, to url: URL) -> Bool {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return false }
        let scale = min(1.0, CGFloat(thumbMax) / max(size.width, size.height))
        let target = NSSize(width: round(size.width * scale), height: round(size.height * scale))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
