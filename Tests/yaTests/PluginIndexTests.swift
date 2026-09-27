import XCTest
@testable import yaCore

/// 关键字规范化、冲突抢占、features 入口、用户覆盖表
final class PluginIndexTests: YaTestCase {

    // MARK: - 规范化

    func testNormalize() {
        XCTAssertEqual(PluginIndex.normalize([" QR ", "QR", "", "  ", "a b", "Clip"]),
                       ["qr", "clip"],
                       "去空白 + 转小写 + 去空串 + 剔除含空格的 + 去重，且保持顺序")
        XCTAssertEqual(PluginIndex.normalize([]), [])
        XCTAssertEqual(PluginIndex.normalize(["A", "a"]), ["a"])
    }

    /// name / description 可能是字符串，也可能是 { en, zh }
    func testText() {
        XCTAssertEqual(PluginIndex.text(of: "标题"), "标题")
        XCTAssertEqual(PluginIndex.text(of: ["zh": "中文", "en": "English"]), "中文 English")
        XCTAssertEqual(PluginIndex.text(of: ["en": "English"]), "English")
        XCTAssertEqual(PluginIndex.text(of: nil), "")
        XCTAssertEqual(PluginIndex.text(of: 123), "")
    }

    // MARK: - 索引

    func testEntriesBasic() throws {
        try makeSimplePlugin("qrcode", keyword: "qr", aliases: ["ewm", "erweima"])
        let entries = PluginIndex.shared.entries()
        XCTAssertEqual(entries.count, 1)
        let e = entries[0]
        XCTAssertEqual(e.id, "qrcode")
        XCTAssertEqual(e.primaryKeyword, "qr")
        XCTAssertEqual(e.keywords, ["qr", "ewm", "erweima"], "主关键字在前")
        XCTAssertEqual(e.declaredKeywords, ["qr", "ewm", "erweima"])
        XCTAssertNil(e.conflictWith)
        XCTAssertEqual(e.activateKeyword, "qr")
        XCTAssertFalse(e.pinyinFull.isEmpty)
    }

    /// 内置插件先入表 → 同关键字时内置赢，用户插件被标 conflictWith
    func testBuiltinWinsConflict() throws {
        try makeSimplePlugin("beta", keyword: "clip", in: builtinDir)
        try makeSimplePlugin("alpha", keyword: "clip")
        let entries = PluginIndex.shared.entries()
        let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        XCTAssertEqual(byId["beta"]?.source, "builtin")
        XCTAssertEqual(byId["beta"]?.primaryKeyword, "clip")
        XCTAssertNil(byId["beta"]?.conflictWith)

        XCTAssertEqual(byId["alpha"]?.primaryKeyword, "", "关键字被抢走后没有可用主关键字")
        XCTAssertEqual(byId["alpha"]?.conflictWith, "beta")
        // 被抢占后 activateKeyword 退回声明的第一个关键字，保证还能进插件
        XCTAssertEqual(byId["alpha"]?.activateKeyword, "clip")
    }

    /// 同级别（都是用户插件）按 id 字典序，先声明者占位
    func testUserPluginsResolveByIdOrder() throws {
        try makeSimplePlugin("alpha", keyword: "dup")
        try makeSimplePlugin("beta", keyword: "dup")
        let byId = Dictionary(uniqueKeysWithValues: PluginIndex.shared.entries().map { ($0.id, $0) })
        XCTAssertEqual(byId["alpha"]?.primaryKeyword, "dup")
        XCTAssertNil(byId["alpha"]?.conflictWith)
        XCTAssertEqual(byId["beta"]?.conflictWith, "alpha")
    }

    /// features[] 入口的关键字与主入口平等竞争
    func testFeatureKeywordConflict() throws {
        try makeSimplePlugin("urlc", keyword: "urlc",
                             features: [["cmd": "enc", "keywords": ["ue"]]])
        try makeSimplePlugin("urlcenc", keyword: "ue")
        let byId = Dictionary(uniqueKeysWithValues: PluginIndex.shared.entries().map { ($0.id, $0) })
        XCTAssertEqual(byId["urlc"]?.features.first?.keywords, ["ue"])
        XCTAssertNil(byId["urlc"]?.features.first?.conflictWith)
        XCTAssertEqual(byId["urlcenc"]?.primaryKeyword, "")
        XCTAssertEqual(byId["urlcenc"]?.conflictWith, "urlc")
    }

    /// 关键字全被抢占的入口不可用（keywords 为空），否则搜索会带出一个点不动的入口
    func testFeatureUnusableWhenAllKeywordsTaken() throws {
        try makeSimplePlugin("owner", keyword: "ue")
        try makeSimplePlugin("urlc", keyword: "urlc",
                             features: [["cmd": "enc", "keywords": ["ue"]]])
        let urlc = PluginIndex.shared.entries().first { $0.id == "urlc" }
        XCTAssertEqual(urlc?.features.count, 1)
        XCTAssertEqual(urlc?.features.first?.keywords, [])
        XCTAssertEqual(urlc?.features.first?.conflictWith, "owner")
    }

    /// features 没写 keywords 时，cmd 自己就是关键字
    func testFeatureDefaultsToCmd() throws {
        try makeSimplePlugin("clip", keyword: "clip",
                             features: [["cmd": "clear"], ["cmd": "  ", "title": "空 cmd"]])
        let clip = PluginIndex.shared.entries().first { $0.id == "clip" }
        XCTAssertEqual(clip?.features.count, 1, "空白 cmd 的入口要被丢掉")
        XCTAssertEqual(clip?.features.first?.cmd, "clear")
        XCTAssertEqual(clip?.features.first?.keywords, ["clear"])
    }

    // MARK: - 用户覆盖表

    func testOverrideWinsAndPersists() throws {
        try makeSimplePlugin("qrcode", keyword: "qr")
        PluginIndex.shared.setKeywords(["myqr", "MYQR"], for: "qrcode")
        XCTAssertEqual(PluginIndex.shared.entry(id: "qrcode")?.keywords, ["myqr"])

        // 覆盖表要真落盘（entries() 每次都会重新读）
        let file = AppPaths.file("keyword-overrides.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(PluginIndex.shared.override(for: "qrcode"), ["myqr"])

        PluginIndex.shared.clearOverride(for: "qrcode")
        XCTAssertNil(PluginIndex.shared.override(for: "qrcode"))
        XCTAssertEqual(PluginIndex.shared.entry(id: "qrcode")?.keywords, ["qr"])
    }

    /// manifestKeywords 必须**忽略**覆盖表：
    /// 否则「用户把自定义关键字原样再保存一次」会被判成「和插件自带一样」→ 覆盖被清掉
    func testManifestKeywordsIgnoresOverride() throws {
        try makeSimplePlugin("qrcode", keyword: "qr", aliases: ["ewm"])
        PluginIndex.shared.setKeywords(["myqr"], for: "qrcode")
        XCTAssertEqual(PluginIndex.shared.manifestKeywords(id: "qrcode"), ["qr", "ewm"])
        XCTAssertEqual(PluginIndex.shared.entry(id: "qrcode")?.declaredKeywords, ["myqr"],
                       "declaredKeywords 有覆盖时返回覆盖值 —— 所以它不能用于「是否与自带一致」的判断")
        XCTAssertEqual(PluginIndex.shared.manifestKeywords(id: "nope"), [])
    }

    func testEmptyOverrideClears() throws {
        try makeSimplePlugin("qrcode", keyword: "qr")
        PluginIndex.shared.setKeywords(["   ", "a b"], for: "qrcode")
        XCTAssertNil(PluginIndex.shared.override(for: "qrcode"), "规范化后为空 = 不覆盖")
    }

    // MARK: - 输出给前端的清单

    func testListPayload() throws {
        try makeSimplePlugin("qrcode", keyword: "qr", aliases: ["ewm"],
                             features: [["cmd": "save", "keywords": ["qrsave"]]])
        let payload = PluginIndex.shared.listPayload()
        XCTAssertEqual(payload.count, 1)
        let p = payload[0]
        XCTAssertEqual(p["id"] as? String, "qrcode")
        XCTAssertEqual(p["keyword"] as? String, "qr")
        XCTAssertEqual(p["activateKeyword"] as? String, "qr")
        XCTAssertEqual(p["conflictWith"] as? String, "")
        XCTAssertEqual(p["iconKey"] as? String, "plugin:qrcode")
        let pinyin = p["pinyin"] as? [String: String]
        XCTAssertNotNil(pinyin?["full"])
        let features = p["features"] as? [[String: Any]]
        XCTAssertEqual(features?.count, 1)
        XCTAssertEqual(features?.first?["titleText"] as? String, "save")
    }

    /// 冲突清单：插件管理页靠它提示「关键字已被 xxx 占用」
    func testConflictsList() throws {
        try makeSimplePlugin("beta", keyword: "clip", in: builtinDir)
        try makeSimplePlugin("alpha", keyword: "clip")
        let conflicts = PluginIndex.shared.conflicts()
        XCTAssertTrue(conflicts.contains { $0.id == "alpha" && $0.keyword == "clip" && $0.ownerId == "beta" })
        XCTAssertFalse(conflicts.contains { $0.id == "beta" })
    }

    // MARK: - 结果提供者（provider）

    /// provider 可以完全没有关键字：它由内容触发，不占关键字
    func testProviderWithoutKeyword() throws {
        try makePlugin("smart", manifest: [
            "id": "smart", "provider": true, "version": "1.0.0", "name": "智能识别"
        ])
        let e = try XCTUnwrap(PluginIndex.shared.entry(id: "smart"))
        XCTAssertTrue(e.isProvider)
        XCTAssertEqual(e.primaryKeyword, "")
        XCTAssertEqual(e.keywords, [])
        XCTAssertEqual(e.activateKeyword, "")
        XCTAssertFalse(e.isEnterable, "没有关键字就不能被「关键字 + 空格」唤醒")
        XCTAssertNil(e.conflictWith, "不占关键字，自然不会和谁冲突")
    }

    /// 双入口：既是 provider，又保留关键字可以显式进入
    func testProviderWithKeywordStaysEnterable() throws {
        try makePlugin("smart", manifest: [
            "id": "smart", "provider": true, "keyword": "s", "keywords": ["s", "smart"]
        ])
        let e = try XCTUnwrap(PluginIndex.shared.entry(id: "smart"))
        XCTAssertTrue(e.isProvider)
        XCTAssertTrue(e.isEnterable)
        XCTAssertEqual(e.activateKeyword, "s")
    }

    /// provider 的关键字一样参与抢占（冲突规则对两种插件一视同仁）
    func testProviderKeywordStillCompetes() throws {
        try makePlugin("beta", manifest: ["id": "beta", "keyword": "s"], in: builtinDir)
        try makePlugin("alpha", manifest: ["id": "alpha", "provider": true, "keyword": "s"])
        let byId = Dictionary(uniqueKeysWithValues: PluginIndex.shared.entries().map { ($0.id, $0) })
        XCTAssertEqual(byId["alpha"]?.conflictWith, "beta")
        XCTAssertEqual(byId["alpha"]?.primaryKeyword, "")
        // 与普通插件一致：关键字被抢后 activateKeyword 退回声明的第一个，仍算可进入
        // （真敲这个关键字会先进抢占者，但至少不会变成一张点不动的卡片）
        XCTAssertTrue(byId["alpha"]?.isEnterable ?? false)
    }

    /// 给 JS 的清单必须带上 provider，否则前端不知道该不该问它
    func testListPayloadCarriesProviderFlag() throws {
        try makeSimplePlugin("clip", keyword: "clip")
        try makePlugin("smart", manifest: ["id": "smart", "provider": true])
        let payload = PluginIndex.shared.listPayload()
        let byId = Dictionary(uniqueKeysWithValues: payload.map { ($0["id"] as? String ?? "", $0) })
        XCTAssertEqual(byId["smart"]?["provider"] as? Bool, true)
        XCTAssertEqual(byId["clip"]?["provider"] as? Bool, false, "没声明就是 false，不能是 nil")
    }
}
