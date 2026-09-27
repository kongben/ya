import Foundation

/// 插件来源：
/// - builtin：打包在 App 内的内置插件（不可删除）
/// - user：~/Library/Application Support/ya/plugins（可导入/删除，同名覆盖内置）
enum PluginLoader {
    /// 内置插件目录（Bundle 内）
    static func builtinDirectory() -> URL? {
        AppResources.webRoot?.appendingPathComponent("plugins")
    }

    /// 用户插件目录（不存在时自动创建；首次运行会从旧版 QuickLauncher 目录迁移）
    static func userDirectory() -> URL { AppPaths.plugins }

    static func list() -> [[String: Any]] {
        var merged: [String: [String: Any]] = [:]
        // 内置先入表，用户插件后入表 → 同 id 时用户插件覆盖内置
        for (dir, source) in [(builtinDirectory(), "builtin"), (userDirectory(), "user")] {
            guard let dir = dir,
                  let subs = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for sub in subs.sorted() where !sub.hasPrefix(".") {
                let manifestPath = dir.appendingPathComponent("\(sub)/plugin.json").path
                guard FileManager.default.fileExists(atPath: manifestPath),
                      let data = FileManager.default.contents(atPath: manifestPath),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                var entry = obj
                entry["id"] = sub
                entry["source"] = source
                merged[sub] = entry
            }
        }
        // 内置在前、用户插件在后，顺序稳定
        return merged.values.sorted { a, b in
            let sa = a["source"] as? String ?? ""
            let sb = b["source"] as? String ?? ""
            if sa == sb { return (a["id"] as? String ?? "") < (b["id"] as? String ?? "") }
            return sa == "builtin"
        }
    }

    static func load(id: String) -> [String: Any] {
        let dirs = [userDirectory(), builtinDirectory()].compactMap { $0 }
        for dir in dirs {
            let pluginDir = dir.appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("plugin.json").path) {
                return [
                    "id": id,
                    "manifest": read(pluginDir, "plugin.json"),
                    "code": read(pluginDir, "main.js"),
                    // 插件 CSS 里的相对 url() 会被换成本地文件的 data URL，见 inlineAssets
                    "css": inlineAssets(in: read(pluginDir, "style.css"), pluginDir: pluginDir)
                ]
            }
        }
        return ["id": id, "manifest": "", "code": "", "css": ""]
    }

    /// 取插件自带资源，返回 data URL（供前端 `api.assetUrl()` 使用）
    /// - Returns: "data:<mime>;base64,..." ；文件不存在 / 过大 / 类型不支持时返回空串
    static func assetDataURL(id: String, name: String) -> String {
        guard let dir = directory(of: id) else { return "" }
        // 只允许插件目录内的相对路径，防止 ../ 越界读到别处
        let safe = (name as NSString).lastPathComponent
        guard !safe.isEmpty, safe != ".", safe != ".." else { return "" }
        let file = dir.appendingPathComponent(safe)
        return dataURL(for: file)
    }

    /// 插件所在目录（用于删除定位）
    static func directory(of id: String) -> URL? {
        let dirs = [userDirectory(), builtinDirectory()].compactMap { $0 }
        for dir in dirs {
            let pluginDir = dir.appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("plugin.json").path) {
                return pluginDir
            }
        }
        return nil
    }

    // MARK: - 资源

    /// CSS 里允许内联的最大单文件体积（超过就不内联，避免把整个 WebView 拖慢）
    private static let maxInlineBytes = 512 * 1024

    private static let mimeByExt: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
        "ico": "image/x-icon", "bmp": "image/bmp", "tiff": "image/tiff",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
    ]

    /// 把 CSS 中的相对 `url(xxx)` 换成 data URL。
    /// 为什么必须内联：WebView 的读权限只在 `Web/` 目录内（`loadFileURL(allowingReadAccessTo:)`），
    /// 用户插件目录在 Application Support 下，**跨目录的 file:// 子资源会被拒**，插件图片会全部裂开。
    private static func inlineAssets(in css: String, pluginDir: URL) -> String {
        guard !css.isEmpty else { return css }
        let pattern = try? NSRegularExpression(
            pattern: #"url\(\s*(['"]?)([^)'"]+)\1\s*\)"#, options: []
        )
        guard let re = pattern else { return css }
        let ns = css as NSString
        let matches = re.matches(in: css, options: [], range: NSRange(location: 0, length: ns.length))
        var out = ""
        var cursor = 0
        for m in matches {
            let raw = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let whole = m.range(at: 0)
            out += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            cursor = whole.location + whole.length

            // 绝对地址 / data: / 渐变等非本地文件，原样保留
            guard !raw.isEmpty,
                  !raw.hasPrefix("data:"),
                  !raw.hasPrefix("#"),
                  !raw.hasPrefix("http://"),
                  !raw.hasPrefix("https://"),
                  !raw.hasPrefix("/") else {
                out += ns.substring(with: whole)
                continue
            }
            let file = pluginDir.appendingPathComponent((raw as NSString).lastPathComponent)
            let url = dataURL(for: file)
            out += url.isEmpty ? ns.substring(with: whole) : "url(\"\(url)\")"
        }
        out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        return out
    }

    private static func dataURL(for file: URL) -> String {
        let fm = FileManager.default
        let path = file.resolvingSymlinksInPath().path
        guard fm.isReadableFile(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[FileAttributeKey.size] as? NSNumber,
              size.intValue <= maxInlineBytes,
              let mime = mimeByExt[file.pathExtension.lowercased()],
              let data = fm.contents(atPath: path) else { return "" }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func read(_ dir: URL, _ name: String) -> String {
        guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
