import XCTest
@testable import yaCore

/// 插件目录枚举、加载、资源内联
final class PluginLoaderTests: YaTestCase {

    func testListMergesBuiltinAndUser() throws {
        try makeSimplePlugin("core", keyword: "core", in: builtinDir)
        try makeSimplePlugin("demo", keyword: "demo")
        let list = PluginLoader.list()
        XCTAssertEqual(list.map { $0["id"] as? String }, ["core", "demo"], "内置在前，同级按 id 排序")
        XCTAssertEqual(list.map { $0["source"] as? String }, ["builtin", "user"])
    }

    /// 同 id 时用户插件覆盖内置（用户改过内置插件的行为要能生效）
    func testUserOverridesBuiltinById() throws {
        try makePlugin("same", manifest: ["keyword": "builtin-kw", "version": "1.0.0"], in: builtinDir)
        try makePlugin("same", manifest: ["keyword": "user-kw", "version": "2.0.0"])
        let list = PluginLoader.list()
        XCTAssertEqual(list.count, 1, "同 id 只留一份")
        XCTAssertEqual(list[0]["keyword"] as? String, "user-kw")
        XCTAssertEqual(list[0]["source"] as? String, "user")
    }

    func testListSkipsDirsWithoutManifest() throws {
        try makeSimplePlugin("demo", keyword: "demo")
        try FileManager.default.createDirectory(
            at: pluginsDir.appendingPathComponent("notaplugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: pluginsDir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        XCTAssertEqual(PluginLoader.list().map { $0["id"] as? String }, ["demo"])
    }

    func testLoadReadsCodeAndCss() throws {
        let dir = try makeSimplePlugin("demo", keyword: "demo")
        try writeFile("main.js", "console.log(1)", in: dir)
        try writeFile("style.css", ".a{color:red}", in: dir)
        let loaded = PluginLoader.load(id: "demo")
        XCTAssertEqual(loaded["id"] as? String, "demo")
        XCTAssertEqual(loaded["code"] as? String, "console.log(1)")
        XCTAssertEqual(loaded["css"] as? String, ".a{color:red}")
    }

    func testLoadMissingPluginReturnsEmpty() {
        let loaded = PluginLoader.load(id: "nope")
        XCTAssertEqual(loaded["code"] as? String, "")
        XCTAssertEqual(loaded["css"] as? String, "")
    }

    /// WebView 读不到插件目录，CSS 里的相对 url() 必须内联成 data URL
    func testInlineAssets() throws {
        let dir = try makeSimplePlugin("demo", keyword: "demo")
        // 1x1 红点 PNG
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")!
        try png.write(to: dir.appendingPathComponent("logo.png"))
        try writeFile("style.css", ".a{background:url(logo.png)} .b{background:url('https://x/y.png')} .c{background:url(data:image/png;base64,AAA)}", in: dir)
        let css = PluginLoader.load(id: "demo")["css"] as? String ?? ""
        XCTAssertTrue(css.contains("url(\"data:image/png;base64,"), "相对路径要内联：\(css)")
        XCTAssertTrue(css.contains("https://x/y.png"), "远端地址原样保留")
        XCTAssertTrue(css.contains("url(data:image/png;base64,AAA)"), "已经是 data URL 的不动")
    }

    /// 插件自带资源只能取自己目录里的 —— 防 ../ 越界
    func testAssetDataURLRejectsTraversal() throws {
        let dir = try makeSimplePlugin("demo", keyword: "demo")
        try writeFile("logo.png", "PNG-IN-PLUGIN", in: dir)
        try writeFile("secret.png", "PNG-OUTSIDE", in: tmp)

        XCTAssertTrue(PluginLoader.assetDataURL(id: "demo", name: "logo.png").hasPrefix("data:image/png;base64,"))
        // ../secret.png 只取 lastPathComponent，所以读的是插件目录下的 secret.png（不存在 → 空串）
        XCTAssertEqual(PluginLoader.assetDataURL(id: "demo", name: "../secret.png"), "",
                       "不能读到插件目录之外")
        XCTAssertEqual(PluginLoader.assetDataURL(id: "demo", name: ".."), "")
    }

    func testAssetUnknownExtensionReturnsEmpty() throws {
        let dir = try makeSimplePlugin("demo", keyword: "demo")
        try writeFile("a.txt", "hello", in: dir)
        XCTAssertEqual(PluginLoader.assetDataURL(id: "demo", name: "a.txt"), "")
    }

    func testDirectoryLookupPrefersUser() throws {
        let userDir = try makeSimplePlugin("demo", keyword: "demo")
        _ = try makeSimplePlugin("demo", keyword: "demo", in: builtinDir)
        XCTAssertEqual(PluginLoader.directory(of: "demo")?.path, userDir.path)
        XCTAssertNil(PluginLoader.directory(of: "nope"))
    }
}
