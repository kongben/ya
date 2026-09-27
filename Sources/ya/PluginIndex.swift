import Foundation

/// 插件索引：关键字解析（别名 + 用户自定义覆盖）、关键字冲突检测、拼音索引
///
/// 关键字规则：
/// - `keyword`：主关键字（必填，除非声明了 `"provider": true`）
/// - `keywords`：别名数组（可选），主关键字自动并入
///
/// 结果提供者（`provider: true`）：不靠关键字触发，而是宿主每次搜索时把输入原文交给它的
/// `onProvide(query)`，由它往主结果列表里贡献几条结果（万能输入框、文件搜索、Snippets
/// 都属于这一类，它们"寄生"在宿主列表里，而不是接管整个面板）。
/// 它可以完全没有关键字，也可以同时声明关键字做显式入口（两者并存，见 PluginIndex.Entry）
/// - 关键字会被规范化：去空白、转小写、不含空格（否则无法与参数分隔）
/// - 用户可在「插件管理」里覆盖关键字，覆盖表写到
///   `~/Library/Application Support/ya/keyword-overrides.json`
///
/// 冲突规则：内置插件优先于用户插件，同级别按 id 字典序，先声明者占用该关键字；
/// 被抢占的关键字不再参与搜索匹配，插件通过 `conflictWith` 标记抢占者。
final class PluginIndex {
    /// 插件的**一个入口**。`cmd` 为空串表示插件主入口（只用 keyword/keywords 触发），
    /// 其余入口由 plugin.json 的 `features[]` 声明，各有自己的关键字。
    struct Feature {
        let cmd: String
        /// 显示名：可能是字符串，也可能是 { en, zh }
        let title: Any
        let declaredKeywords: [String]
        /// 未被抢占的关键字；全部被抢占时该入口不可用
        let keywords: [String]
        /// 抢占了该入口关键字的插件 id
        let conflictWith: String?
        var titleText: String {
            PluginIndex.text(of: title).isEmpty ? cmd : PluginIndex.text(of: title)
        }
    }

    struct Entry {
        let id: String
        let manifest: [String: Any]
        let source: String
        /// 有效主关键字（全部被抢占时为空串）
        let primaryKeyword: String
        /// 未被抢占的关键字（含主关键字，主关键字在前）
        let keywords: [String]
        /// 插件声明的全部关键字（含被抢占的）
        let declaredKeywords: [String]
        /// 抢占了本插件主关键字的插件 id
        let conflictWith: String?
        /// 中英文名称拼接，用于搜索与图标首字母
        let nameText: String
        /// 名称 + 关键字 + id + 描述（小写），前端兜底子串匹配用
        let searchText: String
        let pinyinFull: String
        let pinyinInitials: String
        /// plugin.json 的 version（未声明时为空串，UI 显示 "—"）
        let version: PluginVersion
        /// plugin.json 的 minHostVersion：插件依赖的最低 ya 版本（未声明按 0.1.0 算）
        let minHostVersion: PluginVersion
        /// plugin.json 的 updateUrl：可选，声明后插件管理页可「检查更新」
        let updateUrl: String
        /// `features[]` 声明的其它入口（主入口不在这里）
        let features: [Feature]
        /// plugin.json 的 `provider`：true = 结果提供者，每次搜索都会被问一遍
        let isProvider: Bool

        var iconKey: String { "plugin:\(id)" }
        /// 能否被「关键字 + 空格」直接唤醒：结果提供者可能一个关键字都没有
        var isEnterable: Bool { !activateKeyword.isEmpty }
        /// 进入插件时使用的关键字：优先有效主关键字，被抢占时退回第一个声明关键字
        var activateKeyword: String {
            primaryKeyword.isEmpty ? (declaredKeywords.first ?? "") : primaryKeyword
        }
    }

    struct Conflict {
        let id: String
        let keyword: String
        let ownerId: String
    }

    static let shared = PluginIndex()

    private let lock = NSLock()
    private var overrides: [String: [String]] = [:]

    private var overridesURL: URL { AppPaths.file("keyword-overrides.json") }

    init() {
        reloadOverrides()
    }

    // MARK: - 覆盖表

    func reloadOverrides() {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: overridesURL.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            lock.lock()
            overrides = [:]
            lock.unlock()
            return
        }
        let normalized = json.reduce(into: [String: [String]]()) { acc, pair in
            let kws = Self.normalize(pair.value)
            if !kws.isEmpty { acc[pair.key] = kws }
        }
        lock.lock()
        overrides = normalized
        lock.unlock()
    }

    /// 用户自定义关键字；与插件声明一致时自动清除覆盖（让 plugin.json 后续改动继续生效）
    func setKeywords(_ raw: [String], for id: String) {
        let kws = Self.normalize(raw)
        lock.lock()
        if kws.isEmpty {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = kws
        }
        let snapshot = overrides
        lock.unlock()
        save(snapshot)
    }

    func clearOverride(for id: String) {
        lock.lock()
        overrides.removeValue(forKey: id)
        let snapshot = overrides
        lock.unlock()
        save(snapshot)
    }

    func override(for id: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return overrides[id]
    }

    private func save(_ snapshot: [String: [String]]) {
        // SafeJSON：关键字由用户手输，含 emoji / 特殊字符时 JSONSerialization 会抛 ObjC 异常
        guard let data = SafeJSON.data(snapshot) else { return }
        try? data.write(to: overridesURL, options: .atomic)
    }

    // MARK: - 索引

    /// 每次调用都重新读盘（插件可能刚被导入/删除），成本很低：只是几个小 json
    func entries() -> [Entry] {
        reloadOverrides() // 覆盖表可能刚被插件管理页改写
        let raw = PluginLoader.list() // builtin 优先、同级按 id 排序
        var owner: [String: String] = [:] // 关键字 -> 占用者 id
        var result: [Entry] = []

        for dict in raw {
            let id = dict["id"] as? String ?? ""
            guard !id.isEmpty else { continue }
            let declared = Self.declaredKeywords(id: id, manifest: dict, overrides: currentOverrides())

            var effective: [String] = []
            var conflict: String?
            for kw in declared {
                if let rival = owner[kw] {
                    if conflict == nil { conflict = rival }
                    continue
                }
                owner[kw] = id
                effective.append(kw)
            }

            // features[]：每个入口的关键字同样进冲突表（与插件主关键字平等竞争）
            let features = Self.parseFeatures(manifest: dict, owner: &owner, id: id)

            let nameText = Self.text(of: dict["name"]).isEmpty ? id : Self.text(of: dict["name"])
            let featureText = features
                .map { $0.titleText + " " + $0.declaredKeywords.joined(separator: " ") }
                .joined(separator: " ")
            let searchBase = [
                nameText,
                Self.text(of: dict["description"]),
                declared.joined(separator: " "),
                featureText,
                id
            ].joined(separator: " ")
            let (pyFull, pyInit) = Pinyin.transform(
                nameText + " " + declared.joined(separator: " ") + " " + featureText
            )

            result.append(Entry(
                id: id,
                manifest: dict,
                source: dict["source"] as? String ?? "user",
                primaryKeyword: effective.first ?? "",
                keywords: effective,
                declaredKeywords: declared,
                conflictWith: conflict,
                nameText: nameText,
                searchText: searchBase.lowercased(),
                pinyinFull: pyFull,
                pinyinInitials: pyInit,
                version: PluginVersion(raw: dict["version"] as? String ?? ""),
                minHostVersion: PluginImporter.requiredHostVersion(of: dict),
                updateUrl: (dict["updateUrl"] as? String) ?? (dict["update_url"] as? String) ?? "",
                features: features,
                isProvider: (dict["provider"] as? Bool) ?? false
            ))
        }
        return result
    }

    func entry(id: String) -> Entry? {
        entries().first { $0.id == id }
    }

    /// 所有被抢占的关键字（插件管理页/导入后提示用）。主入口与 features 的关键字都算。
    func conflicts() -> [Conflict] {
        var list: [Conflict] = []
        // entries() 每次都会重新读盘，只算一次
        for e in entries() {
            guard let rival = e.conflictWith else { continue }
            for kw in e.declaredKeywords where !e.keywords.contains(kw) {
                list.append(Conflict(id: e.id, keyword: kw, ownerId: rival))
            }
            for f in e.features {
                guard let rival = f.conflictWith else { continue }
                for kw in f.declaredKeywords where !f.keywords.contains(kw) {
                    list.append(Conflict(id: e.id, keyword: kw, ownerId: rival))
                }
            }
        }
        return list
    }

    /// 插件 **plugin.json 里声明的**关键字（忽略用户覆盖）。
    ///
    /// 判定「用户填的是不是和插件自带的一样」必须用它：拿 `entry.declaredKeywords`
    /// 会在已有覆盖时返回覆盖值，于是「用户把自定义关键字原样再保存一次」会被判成
    /// 「与插件自带一致」→ 覆盖被清掉 → 关键字悄悄退回 plugin.json 的值。
    func manifestKeywords(id: String) -> [String] {
        guard let dict = PluginLoader.list().first(where: { ($0["id"] as? String) == id }) else {
            return []
        }
        return Self.declaredKeywords(id: id, manifest: dict, overrides: [:])
    }

    /// 供 JS 使用的清单（含搜索所需的拼音与关键字字段，搜索在前端内存中完成）
    func listPayload() -> [[String: Any]] {
        entries().map { e in
            var out: [String: Any] = e.manifest
            out["id"] = e.id
            out["source"] = e.source
            out["keyword"] = e.primaryKeyword
            out["activateKeyword"] = e.activateKeyword
            out["keywords"] = e.keywords
            out["declaredKeywords"] = e.declaredKeywords
            out["conflictWith"] = e.conflictWith ?? ""
            out["iconKey"] = e.iconKey
            out["version"] = e.version.display
            out["searchText"] = e.searchText
            out["pinyin"] = ["full": e.pinyinFull, "initials": e.pinyinInitials]
            out["provider"] = e.isProvider
            // features 用解析后的结果覆盖 manifest 里的原始字段（带冲突处理与有效关键字）
            out["features"] = e.features.map { f -> [String: Any] in
                [
                    "cmd": f.cmd,
                    "title": f.title,
                    "titleText": f.titleText,
                    "keywords": f.keywords,
                    "declaredKeywords": f.declaredKeywords,
                    "conflictWith": f.conflictWith ?? "",
                ]
            }
            return out
        }
    }

    // MARK: - 私有

    private func currentOverrides() -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        return overrides
    }

    private static func declaredKeywords(id: String,
                                         manifest: [String: Any],
                                         overrides: [String: [String]]) -> [String] {
        if let custom = overrides[id] { return custom }
        var list: [String] = []
        if let k = manifest["keyword"] as? String { list.append(k) }
        if let arr = manifest["keywords"] as? [String] { list.append(contentsOf: arr) }
        return normalize(list)
    }

    /// 解析 plugin.json 的 `features[]`。每项是一个额外入口，有自己的关键字与主入口平等参与抢占。
    private static func parseFeatures(manifest: [String: Any],
                                      owner: inout [String: String],
                                      id: String) -> [Feature] {
        guard let arr = manifest["features"] as? [[String: Any]] else { return [] }
        var out: [Feature] = []
        for item in arr {
            let cmd = (item["cmd"] as? String) ?? (item["code"] as? String) ?? ""
            guard !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let raw: [String]
            if let ks = item["keywords"] as? [String] { raw = ks }
            else if let k = item["keyword"] as? String { raw = [k] }
            else { raw = [cmd] }
            let declaredKw = normalize(raw)
            var effective: [String] = []
            var conflict: String?
            for kw in declaredKw {
                if let rival = owner[kw] {
                    if conflict == nil { conflict = rival }
                    continue
                }
                owner[kw] = id
                effective.append(kw)
            }
            out.append(Feature(
                cmd: cmd,
                title: item["title"] ?? item["name"] ?? cmd,
                declaredKeywords: declaredKw,
                keywords: effective,
                conflictWith: conflict
            ))
        }
        return out
    }

    /// 规范化：去首尾空白、转小写、剔除空串/含空白的串、去重
    static func normalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            let kw = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !kw.isEmpty,
                  kw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  seen.insert(kw).inserted else { continue }
            out.append(kw)
        }
        return out
    }

    /// name/description 可能是字符串，也可能是 { en, zh }
    static func text(of value: Any?) -> String {
        if let s = value as? String { return s }
        if let d = value as? [String: Any] {
            return [d["zh"] as? String, d["en"] as? String]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return ""
    }
}
