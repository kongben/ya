import Foundation

/// 使用历史：**应用和插件共用一条时间线**（最新在前），最多 12 条。
///
/// 以前是 apps / plugins 两个独立数组，前端只能「先画一排应用、再画一排插件」——
/// 刚用过的插件永远被压在应用后面，那不叫「最近使用」。现在每次记录都带时间戳，
/// 读出来就是真正的最近顺序，前端照着画即可。
///
/// 持久化到 UserDefaults（`ya.usage.recent`）。旧版的两个数组只用来做一次性迁移。
final class UsageHistory {
    private var entries: [[String: Any]] = [] // [{kind:"app", name, path, ts} | {kind:"plugin", id, ts}]
    /// 12 = 前端两排（一行 6 个）。应用插件共用一份额度，谁最近谁在前
    private let maxItems = 12
    private let defaults: UserDefaults
    private let recentKey = "ya.usage.recent"
    private let legacyAppsKey = "ya.usage.apps"
    private let legacyPluginsKey = "ya.usage.plugins"

    /// `defaults` 可注入：单测传一个临时 suite，就不会读写真实的用户偏好
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 迁移只针对真实的 standard（把旧版 quicklauncher.* 搬过来），测试 suite 不需要
        if defaults === UserDefaults.standard { LegacyMigrator.migrateDefaults() }
        if let raw = defaults.array(forKey: recentKey) as? [[String: Any]] {
            entries = raw
        } else {
            entries = Self.migrate(
                apps: defaults.array(forKey: legacyAppsKey) as? [[String: String]] ?? [],
                plugins: defaults.stringArray(forKey: legacyPluginsKey) ?? []
            )
            if !entries.isEmpty { save() }
        }
    }

    /// 旧数据没有时间戳，只有两个数组各自内部的先后。迁移只能猜：应用和插件**交替**排，
    /// ts 按名次递减 —— 至少不会把某一类整体压到后面去
    private static func migrate(apps: [[String: String]], plugins: [String]) -> [[String: Any]] {
        let now = Date().timeIntervalSince1970
        var out: [[String: Any]] = []
        let n = max(apps.count, plugins.count)
        for i in 0..<n {
            if i < apps.count {
                out.append([
                    "kind": "app",
                    "name": apps[i]["name"] ?? "",
                    "path": apps[i]["path"] ?? "",
                    "ts": now - Double(i) * 2,
                ])
            }
            if i < plugins.count {
                out.append(["kind": "plugin", "id": plugins[i], "ts": now - Double(i) * 2 - 1])
            }
        }
        return out
    }

    private func save() {
        defaults.set(entries, forKey: recentKey)
    }

    /// 按时间倒序。**ts 相同时保持插入顺序**（Swift 的 sort 不稳定，必须自己带下标做稳定排序）
    private func sorted() -> [[String: Any]] {
        entries.enumerated()
            .sorted { a, b in
                let ta = a.element["ts"] as? Double ?? 0
                let tb = b.element["ts"] as? Double ?? 0
                if ta != tb { return ta > tb }
                return a.offset < b.offset
            }
            .map { $0.element }
    }

    func recordApp(name: String, path: String) {
        // 同一个路径改名重装：按 path 去重，只更新名字并提到最前
        entries.removeAll { ($0["kind"] as? String) == "app" && ($0["path"] as? String) == path }
        entries.insert(
            ["kind": "app", "name": name, "path": path, "ts": Date().timeIntervalSince1970],
            at: 0
        )
        trimAndSave()
    }

    func recordPlugin(id: String) {
        entries.removeAll { ($0["kind"] as? String) == "plugin" && ($0["id"] as? String) == id }
        entries.insert(["kind": "plugin", "id": id, "ts": Date().timeIntervalSince1970], at: 0)
        trimAndSave()
    }

    private func trimAndSave() {
        if entries.count > maxItems { entries = Array(entries.prefix(maxItems)) }
        save()
    }

    /// 最近使用（应用 + 插件混排，最新在前）
    func recent() -> [[String: Any]] { Array(sorted().prefix(maxItems)) }

    /// 只取应用 / 只取插件：单测与将来可能的分类统计用
    func recentApps() -> [[String: String]] {
        sorted().compactMap { e in
            guard (e["kind"] as? String) == "app" else { return nil }
            return ["name": (e["name"] as? String) ?? "", "path": (e["path"] as? String) ?? ""]
        }
    }

    func recentPluginIds() -> [String] {
        sorted().compactMap { e in
            (e["kind"] as? String) == "plugin" ? ((e["id"] as? String) ?? "") : nil
        }
    }

    /// 丢掉已经不存在的插件（改过 id、被删掉、测试残留）。
    /// 不清的话「最近使用」会被这些僵尸 id 占住 —— 实测记录里堆着 calculator / url / hello
    /// 三个早已不存在的 id，能匹配上的只剩一个，看上去就像「最近插件永远只有那一个」。
    /// 应用条目不受影响（应用被卸载了也该留着，用户可以自己看着删）。
    func prunePlugins(keeping validIds: Set<String>) {
        let before = entries.count
        entries.removeAll {
            ($0["kind"] as? String) == "plugin" && !validIds.contains(($0["id"] as? String) ?? "")
        }
        if entries.count != before { save() }
    }
}
