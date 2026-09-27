import XCTest
@testable import yaCore

/// 最近使用的应用 / 插件 —— **共用一条时间线**（坑 29 就出在这里：僵尸 id 不清、上限判断写错，
/// 表现是「导入了 3 个插件，最近插件永远只有 1 个」；现在两个数组也合成一条了）
final class UsageHistoryTests: XCTestCase {
    /// 固定名字的独立 suite：绝不碰用户真实的 UserDefaults。
    /// 不用 UUID —— 每次跑测试造一个域，清理稍微漏一次就在磁盘上攒下一堆垃圾
    /// （历史上 `ya.test.<UUID>` 攒了一百多个，因为 removePersistentDomain 调错了对象）
    private let suite = "ya.tests.usagehistory"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite) // 上一个用例可能留下东西
    }

    override func tearDown() {
        // 必须对这个 suite 实例调：standard.removePersistentDomain 只清 standard 域
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        defaults = nil
        super.tearDown()
    }

    private func make() -> UsageHistory { UsageHistory(defaults: defaults) }

    /// recent() 里每条是 [kind/name/path/id/ts]，压成 "app:Safari" / "plugin:qrcode" 方便比对
    private func shape(_ h: UsageHistory) -> [String] {
        h.recent().map { e in
            let kind = e["kind"] as? String ?? ""
            return kind == "app" ? "app:\(e["name"] as? String ?? "")" : "plugin:\(e["id"] as? String ?? "")"
        }
    }

    private func app(_ name: String) -> [String: String] {
        ["name": name, "path": "/Applications/\(name).app"]
    }

    func testRecordPluginMovesToFront() {
        let h = make()
        h.recordPlugin(id: "a")
        h.recordPlugin(id: "b")
        XCTAssertEqual(shape(h), ["plugin:b", "plugin:a"])
        h.recordPlugin(id: "a")
        XCTAssertEqual(shape(h), ["plugin:a", "plugin:b"], "重复记录要提到最前，不能留两条")
    }

    /// 应用和插件混在一条时间线上：刚用过的插件必须排在之前用过的应用前面
    func testAppsAndPluginsShareOneTimeline() {
        let h = make()
        h.recordApp(name: "Safari", path: "/Applications/Safari.app")
        h.recordPlugin(id: "qrcode")
        XCTAssertEqual(shape(h), ["plugin:qrcode", "app:Safari"])
        // 再用一次 Safari → 它回到最前
        h.recordApp(name: "Safari", path: "/Applications/Safari.app")
        XCTAssertEqual(shape(h), ["app:Safari", "plugin:qrcode"])
    }

    func testLimitIsTwelve() {
        let h = make()
        for i in 0..<18 { h.recordPlugin(id: "p\(i)") }
        XCTAssertEqual(h.recentPluginIds().count, 12)
        XCTAssertEqual(h.recentPluginIds().first, "p17")
        XCTAssertFalse(h.recentPluginIds().contains("p0"), "超出上限的是最旧的")
    }

    /// 应用插件共用一份额度：12 个应用用满之后，新插件会把最旧的应用挤掉
    func testLimitIsSharedBetweenAppsAndPlugins() {
        let h = make()
        for i in 0..<12 { h.recordApp(name: "App\(i)", path: "/Applications/App\(i).app") }
        XCTAssertEqual(h.recent().count, 12)
        h.recordPlugin(id: "qrcode")
        XCTAssertEqual(h.recent().count, 12)
        XCTAssertEqual(shape(h).first, "plugin:qrcode")
        XCTAssertFalse(shape(h).contains("app:App0"), "被挤掉的是最旧的那个（App0 最先记录）")
    }

    /// 僵尸 id（改过 id / 删掉的插件）必须清掉，否则「最近使用」被它们占满
    func testPrunePlugins() {
        let h = make()
        h.recordApp(name: "Safari", path: "/Applications/Safari.app")
        for id in ["url", "calculator", "qrcode", "hello"] { h.recordPlugin(id: id) }
        h.prunePlugins(keeping: ["qrcode", "clipboard"])
        XCTAssertEqual(h.recentPluginIds(), ["qrcode"])
        XCTAssertEqual(h.recentApps().count, 1, "清的是插件，应用不受影响")
    }

    func testPrunePersists() {
        let h = make()
        h.recordPlugin(id: "ghost")
        h.recordPlugin(id: "real")
        h.prunePlugins(keeping: ["real"])
        // 换一个实例读同一份 defaults，确认清完就落盘了
        XCTAssertEqual(make().recentPluginIds(), ["real"])
    }

    func testPruneNoopWhenNothingRemoved() {
        let h = make()
        h.recordPlugin(id: "real")
        h.prunePlugins(keeping: ["real", "other"])
        XCTAssertEqual(h.recentPluginIds(), ["real"])
    }

    func testRecordAppDedupesByPath() {
        let h = make()
        h.recordApp(name: "Safari", path: "/Applications/Safari.app")
        h.recordApp(name: "Chrome", path: "/Applications/Chrome.app")
        // 同一个路径改个名字：按 path 去重，只更新名字并提到最前
        h.recordApp(name: "Safari 2", path: "/Applications/Safari.app")
        XCTAssertEqual(h.recentApps().count, 2)
        XCTAssertEqual(h.recentApps().first?["path"], "/Applications/Safari.app")
        XCTAssertEqual(h.recentApps().first?["name"], "Safari 2")
    }

    /// 旧版是两个数组（ya.usage.apps / ya.usage.plugins），升级后要能接着用
    func testMigratesLegacyArrays() {
        defaults.set([app("Safari"), app("Notes")], forKey: "ya.usage.apps")
        defaults.set(["qrcode", "clipboard"], forKey: "ya.usage.plugins")
        let h = make()
        XCTAssertEqual(h.recent().count, 4)
        XCTAssertEqual(Set(shape(h)), ["app:Safari", "app:Notes", "plugin:qrcode", "plugin:clipboard"])
        // 迁移后要落盘，下次直接读新 key
        XCTAssertEqual(make().recent().count, 4)
    }

    func testEmptyByDefault() {
        let h = make()
        XCTAssertTrue(h.recent().isEmpty)
        XCTAssertEqual(h.recentApps(), [])
        XCTAssertEqual(h.recentPluginIds(), [])
    }
}
