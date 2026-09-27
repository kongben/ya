import Foundation

enum PluginError: LocalizedError, Equatable {
    case unzipFailed(String)
    case manifestMissing
    case invalidManifest
    case builtinCannotDelete
    case notInstalled
    case compilerUnavailable
    case compileFailed(String)
    /// 插件声明的最低宿主版本比当前 ya 高：装了也用不了，所以直接拒绝
    case hostTooOld(plugin: String, required: String, current: String)

    private var zh: Bool { AppSettings.isZh }

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let out):
            return zh ? "解压失败：\(out)" : "Unzip failed: \(out)"
        case .hostTooOld(let plugin, let required, let current):
            return zh
                ? "插件「\(plugin)」需要 ya \(required) 或更高版本，当前是 \(current)。请先升级 ya 再导入，否则装上了也用不了。"
                : "Plugin \"\(plugin)\" requires ya \(required) or newer (you have \(current)). Please update ya before installing — otherwise it won't work."
        case .manifestMissing:
            return zh ? "压缩包里没有找到 plugin.json" : "plugin.json not found in the archive"
        case .invalidManifest:
            return zh ? "plugin.json 无效（缺少 keyword / keywords 字段）" : "Invalid plugin.json (missing keyword)"
        case .builtinCannotDelete:
            return zh ? "内置插件不能删除" : "Built-in plugins cannot be deleted"
        case .notInstalled:
            return zh ? "插件不存在" : "Plugin not found"
        case .compilerUnavailable:
            return zh ? "插件只有 main.ts，且本机找不到 tsc 编译器" : "Plugin ships only main.ts and no tsc compiler was found"
        case .compileFailed(let out):
            return zh ? "TypeScript 编译失败：\(out)" : "TypeScript compile failed: \(out)"
        }
    }
}

/// 导入结果：除了 id，还带上版本变化，让调用方能告诉用户"装了新版还是旧版"
struct PluginImportResult {
    enum Kind: Equatable {
        case installed    // 首次安装
        case updated      // 版本号变大
        case downgraded   // 版本号变小（装了旧包）
        case reinstalled  // 版本相同，只是覆盖
    }

    let id: String
    let newVersion: PluginVersion
    /// 已安装过的版本；首次安装为 nil
    let oldVersion: PluginVersion?

    var kind: Kind {
        guard let old = oldVersion else { return .installed }
        if newVersion > old { return .updated }
        if newVersion < old { return .downgraded }
        return .reinstalled
    }

    /// 版本变化描述，如 "1.0.0 → 1.2.0"；首次安装只有新版本
    var versionChange: String {
        guard let old = oldVersion else { return newVersion.display }
        return "\(old.display) → \(newVersion.display)"
    }

    /// 给用户看的一句话结果（插件管理页 / 深链安装共用）
    var localizedSummary: String {
        let zh = AppSettings.isZh
        switch kind {
        case .installed:
            return zh ? "已安装插件：\(id)（\(newVersion.display)）"
                      : "Installed \(id) (\(newVersion.display))"
        case .updated:
            return zh ? "已更新插件：\(id) \(versionChange)"
                      : "Updated \(id): \(versionChange)"
        case .downgraded:
            return zh ? "⚠️ 已降级插件：\(id) \(versionChange)（装的是旧版本）"
                      : "⚠️ Downgraded \(id): \(versionChange) (older than installed)"
        case .reinstalled:
            return zh ? "已覆盖安装：\(id)（版本未变，\(newVersion.display)）"
                      : "Reinstalled \(id) (same version \(newVersion.display))"
        }
    }
}

/// 插件导入（zip）与删除
enum PluginImporter {
    /// plugin.json 没声明 `minHostVersion` 时按这个版本算：
    /// 即"只依赖 ya 最初那批能力"的插件，任何正式版 ya 都装得上
    static let defaultMinHostVersion = PluginVersion(raw: "0.1.0")

    /// 当前宿主版本（plugin.json 的 `minHostVersion` 跟它比）
    static var hostVersion: PluginVersion { PluginVersion(raw: NativeServices.appVersion) }

    /// 插件要求的最低宿主版本。没写、或写得解析不出数字时，退回默认值
    static func requiredHostVersion(of json: [String: Any]) -> PluginVersion {
        let v = PluginVersion(raw: (json["minHostVersion"] as? String) ?? "")
        return v.parts.isEmpty ? defaultMinHostVersion : v
    }

    /// 导入 zip 包，返回插件 id 与版本变化
    @discardableResult
    static func importZip(at zipURL: URL) throws -> PluginImportResult {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ya-import-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        do {
            _ = try run("/usr/bin/ditto", ["-xk", zipURL.path, tmp.path])
        } catch {
            throw PluginError.unzipFailed(String(describing: error))
        }

        guard let manifestURL = findManifest(in: tmp) else { throw PluginError.manifestMissing }
        let srcDir = manifestURL.deletingLastPathComponent()
        // zip slip 防护：解压产物必须仍在临时目录内
        guard isContained(srcDir, in: tmp) else { throw PluginError.manifestMissing }

        guard let data = fm.contents(atPath: manifestURL.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              hasKeyword(json) else {
            throw PluginError.invalidManifest
        }

        let rawId = (json["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? srcDir.lastPathComponent
        let id = sanitize(rawId)

        // 依赖的宿主版本：声明了就得够，不然装上也是个坏的（缺 bridge / 缺 API）
        let required = requiredHostVersion(of: json)
        if hostVersion < required {
            throw PluginError.hostTooOld(plugin: id,
                                         required: required.display,
                                         current: hostVersion.display)
        }

        // 只有 .ts 没有 .js 时，尝试就地编译
        let jsPath = srcDir.appendingPathComponent("main.js").path
        let tsPath = srcDir.appendingPathComponent("main.ts").path
        if !fm.fileExists(atPath: jsPath) && fm.fileExists(atPath: tsPath) {
            try compileTypeScript(at: srcDir)
        }

        // 先记下旧版本，装完才能说出「1.0.0 → 1.2.0」这种变化
        let oldVersion = installedVersion(id: id)
        let newVersion = PluginVersion(raw: json["version"] as? String ?? "")

        // 原子替换：先落到暂存目录，再整体换入。
        // 旧实现是先 remove 再 move —— 一旦 move 失败，原插件就没了。
        let dest = PluginLoader.userDirectory().appendingPathComponent(id)
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(id).staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.moveItem(at: srcDir, to: staging)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dest)
        }
        return PluginImportResult(id: id, newVersion: newVersion, oldVersion: oldVersion)
    }

    /// 已安装插件的版本；没装过返回 nil
    static func installedVersion(id: String) -> PluginVersion? {
        guard let dir = PluginLoader.directory(of: id),
              let data = FileManager.default.contents(atPath: dir.appendingPathComponent("plugin.json").path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PluginVersion(raw: json["version"] as? String ?? "")
    }

    static func delete(id: String) throws {
        let fm = FileManager.default
        guard let dir = PluginLoader.directory(of: id) else { throw PluginError.notInstalled }
        if dir.deletingLastPathComponent().path == PluginLoader.builtinDirectory()?.path {
            throw PluginError.builtinCannotDelete
        }
        try fm.removeItem(at: dir)
    }

    // MARK: - 私有

    /// 至少要有一个可用关键字：keyword 或 keywords 数组。
    ///
    /// 例外：`"provider": true` 的**结果提供者**插件（见 PluginIndex 说明）——
    /// 它由输入内容触发、不占关键字，所以允许完全没有关键字。
    private static func hasKeyword(_ json: [String: Any]) -> Bool {
        if (json["provider"] as? Bool) == true { return true }
        if let k = json["keyword"] as? String, !k.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        if let arr = json["keywords"] as? [String],
           arr.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return true
        }
        return false
    }

    private static func sanitize(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        return raw.lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    /// path 是否在 root 内（解析符号链接后比较，防止 ../ 穿越）
    private static func isContained(_ path: URL, in root: URL) -> Bool {
        let canonical = path.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return canonical == rootPath || canonical.hasPrefix(rootPath + "/")
    }

    private static func findManifest(in dir: URL) -> URL? {
        let fm = FileManager.default
        let direct = dir.appendingPathComponent("plugin.json")
        if fm.fileExists(atPath: direct.path) { return direct }
        // 常见情况：zip 里包了一层目录
        if let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for sub in subs where sub.hasDirectoryPath {
                let nested = sub.appendingPathComponent("plugin.json")
                if fm.fileExists(atPath: nested.path) { return nested }
            }
        }
        return nil
    }

    private static func compileTypeScript(at dir: URL) throws {
        let fm = FileManager.default
        let tscCandidates = [
            "/Users/zhouyefei/.workbuddy/binaries/node/workspace/node_modules/typescript/bin/tsc",
            "/opt/homebrew/lib/node_modules/typescript/bin/tsc",
            "/usr/local/lib/node_modules/typescript/bin/tsc",
        ]
        let nodeCandidates = [
            "/Users/zhouyefei/.workbuddy/binaries/node/versions/22.22.2-3/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ]
        guard let tsc = tscCandidates.first(where: { fm.fileExists(atPath: $0) }),
              let node = nodeCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
            throw PluginError.compilerUnavailable
        }
        let ts = dir.appendingPathComponent("main.ts").path
        let js = dir.appendingPathComponent("main.js").path
        do {
            _ = try run(node, [tsc, ts, "--target", "ES2020", "--lib", "ES2020,DOM", "--outFile", js])
        } catch {
            throw PluginError.compileFailed(String(describing: error))
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw PluginError.compileFailed(out.isEmpty ? "exit \(process.terminationStatus)" : out)
        }
        return out
    }
}
