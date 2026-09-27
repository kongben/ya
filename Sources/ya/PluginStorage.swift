import Foundation

/// 插件本地键值存储（类 localStorage，对应 uTools 的 dbStorage）
/// 每个插件一个 JSON 文件，位于 ~/Library/Application Support/ya/storage/
/// （与 plugins/ 分开，避免存储文件混进插件目录被当成插件扫描）
final class PluginStorage {
    private let dir: URL

    /// `dir` 可注入：单测指向临时目录，生产走 AppPaths.storage
    init(dir: URL = AppPaths.storage) {
        self.dir = dir
        // 目录可能还不存在（首次写、或注入了一个新目录）。
        // 不建目录的话 save() 的 try? 会把写入失败悄悄吞掉，表现为「存了读不出来」。
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func get(plugin: String, key: String) -> String {
        load(plugin)[key] ?? ""
    }

    func set(plugin: String, key: String, value: String) {
        var dict = load(plugin)
        dict[key] = value
        save(plugin, dict)
    }

    func remove(plugin: String, key: String) {
        var dict = load(plugin)
        dict.removeValue(forKey: key)
        save(plugin, dict)
    }

    private func file(_ plugin: String) -> URL {
        let safe = plugin.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let name = safe.isEmpty ? "global" : safe
        return dir.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func load(_ plugin: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: file(plugin).path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return obj
    }

    private func save(_ plugin: String, _ dict: [String: String]) {
        // SafeJSON：避免 JSONSerialization 对特殊字符串抛 ObjC 异常导致闪退
        let json = SafeJSON.object(dict)
        try? json.write(to: file(plugin), atomically: true, encoding: .utf8)
    }
}
