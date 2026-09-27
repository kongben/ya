import XCTest
@testable import yaCore

/// 插件导入（zip）与删除。装错版本、装到别的目录、覆盖安装丢插件都是这里的地盘
final class PluginImporterTests: YaTestCase {

    /// 造一个插件目录并打成 zip（ditto 是系统自带的，比 zip 命令更可控）
    private func zipPlugin(_ folder: String, _ manifest: [String: Any], files: [String: String] = [:]) throws -> URL {
        let src = tmp.appendingPathComponent("src/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: src.appendingPathComponent("plugin.json"))
        for (name, content) in files {
            try content.write(to: src.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let zip = tmp.appendingPathComponent("\(folder).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-ck", "--sequesterRsrc", "--keepParent", src.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return zip
    }

    func testImportAndSanitizeId() throws {
        let zip = try zipPlugin("My Plugin!", ["id": "My Plugin!", "keyword": "demo", "version": "1.0.0"])
        let result = try PluginImporter.importZip(at: zip)
        XCTAssertEqual(result.id, "my-plugin", "id 要消毒成合法目录名")
        XCTAssertEqual(result.kind, PluginImportResult.Kind.installed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("my-plugin/plugin.json").path))
    }

    /// zip 里没写 id 时用目录名
    func testIdFallsBackToFolderName() throws {
        let zip = try zipPlugin("demo", ["keyword": "demo"])
        XCTAssertEqual(try PluginImporter.importZip(at: zip).id, "demo")
    }

    func testVersionChange() throws {
        let v1 = try zipPlugin("demo", ["id": "demo", "keyword": "demo", "version": "1.0.0"])
        XCTAssertEqual(try PluginImporter.importZip(at: v1).kind, .installed)

        let v2 = try zipPlugin("demo", ["id": "demo", "keyword": "demo", "version": "1.2.0"])
        let up = try PluginImporter.importZip(at: v2)
        XCTAssertEqual(up.kind, PluginImportResult.Kind.updated)
        XCTAssertEqual(up.versionChange, "1.0.0 → 1.2.0")

        let v0 = try zipPlugin("demo", ["id": "demo", "keyword": "demo", "version": "0.9.0"])
        XCTAssertEqual(try PluginImporter.importZip(at: v0).kind, PluginImportResult.Kind.downgraded)
    }

    func testInstalledVersion() throws {
        XCTAssertNil(PluginImporter.installedVersion(id: "demo"))
        let zip = try zipPlugin("demo", ["id": "demo", "keyword": "demo", "version": "2.1"])
        _ = try PluginImporter.importZip(at: zip)
        XCTAssertEqual(PluginImporter.installedVersion(id: "demo"), PluginVersion(raw: "2.1"))
    }

    /// 缺关键字的插件一律拒绝：装了也搜不到
    func testRejectsManifestWithoutKeyword() throws {
        let zip = try zipPlugin("bad", ["id": "bad"])
        XCTAssertThrowsError(try PluginImporter.importZip(at: zip)) { error in
            XCTAssertEqual(error as? PluginError, PluginError.invalidManifest)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginsDir.appendingPathComponent("bad").path))
    }

    func testRejectsNonZip() throws {
        let junk = tmp.appendingPathComponent("junk.zip")
        try "not a zip".write(to: junk, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PluginImporter.importZip(at: junk))
    }

    func testDelete() throws {
        try makeSimplePlugin("demo", keyword: "demo")
        XCTAssertNoThrow(try PluginImporter.delete(id: "demo"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginsDir.appendingPathComponent("demo").path))
        XCTAssertThrowsError(try PluginImporter.delete(id: "demo")) { error in
            XCTAssertEqual(error as? PluginError, PluginError.notInstalled)
        }
    }

    /// 内置插件不允许删（删了内置目录里的东西，升级 App 才补得回来）
    func testBuiltinCannotDelete() throws {
        try makeSimplePlugin("core", keyword: "core", in: builtinDir)
        XCTAssertThrowsError(try PluginImporter.delete(id: "core")) { error in
            XCTAssertEqual(error as? PluginError, PluginError.builtinCannotDelete)
        }
    }

    /// 覆盖安装：旧版本目录里的文件必须被换掉，不能留下旧 main.js
    func testOverwriteReplacesStaleFiles() throws {
        let v1 = try zipPlugin("demo", ["id": "demo", "keyword": "demo", "version": "1.0.0"],
                               files: ["main.js": "console.log('old')"])
        _ = try PluginImporter.importZip(at: v1)
        let v2 = try zipPlugin("demo", ["id": "demo", "keyword": "demo", "version": "1.1.0"],
                               files: ["main.js": "console.log('new')"])
        _ = try PluginImporter.importZip(at: v2)
        let js = pluginsDir.appendingPathComponent("demo/main.js")
        XCTAssertEqual(contents(js), "console.log('new')")
    }

    /// 结果提供者可以不声明关键字（普通插件没有关键字会被拒）
    func testProviderPluginWithoutKeywordImports() throws {
        let zip = try zipPlugin("smart", [
            "id": "smart", "provider": true, "version": "1.0.0", "name": "智能识别"
        ], files: ["main.js": "console.log('smart')"])
        let result = try PluginImporter.importZip(at: zip)
        XCTAssertEqual(result.id, "smart")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("smart/plugin.json").path))
    }

    /// 既没关键字又没声明 provider → 仍然拒绝
    func testPluginWithoutKeywordAndWithoutProviderRejected() throws {
        let zip = try zipPlugin("orphan", ["id": "orphan", "version": "1.0.0"])
        XCTAssertThrowsError(try PluginImporter.importZip(at: zip)) { error in
            XCTAssertEqual(error as? PluginError, PluginError.invalidManifest)
        }
    }

    // MARK: - 最低宿主版本（minHostVersion）

    func testDefaultMinHostVersionIsBaseline() {
        XCTAssertEqual(PluginImporter.defaultMinHostVersion, PluginVersion(raw: "0.1.0"))
    }

    /// 没写 minHostVersion 的插件按默认（0.1.0）算，当前 ya 装得上
    func testPluginWithoutMinHostVersionImports() throws {
        let zip = try zipPlugin("plain", ["id": "plain", "keyword": "plain", "version": "1.0.0"])
        XCTAssertEqual(try PluginImporter.importZip(at: zip).id, "plain")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("plain/plugin.json").path))
    }

    /// 声明的版本不高于当前 ya → 放行（相等 / 更低都要过）
    func testSatisfiedMinHostVersionImports() throws {
        let same = try zipPlugin("same", ["id": "same", "keyword": "same",
                                          "minHostVersion": PluginImporter.hostVersion.display])
        XCTAssertEqual(try PluginImporter.importZip(at: same).id, "same")

        let lower = try zipPlugin("lower", ["id": "lower", "keyword": "lower",
                                            "minHostVersion": "0.0.1"])
        XCTAssertEqual(try PluginImporter.importZip(at: lower).id, "lower")
    }

    /// 声明了比当前 ya 更高的版本 → 拒绝，并且不能留下半个插件目录
    func testHostTooOldRejected() throws {
        let zip = try zipPlugin("future", ["id": "future", "keyword": "future",
                                           "version": "2.0.0", "minHostVersion": "99.0.0"])
        XCTAssertThrowsError(try PluginImporter.importZip(at: zip)) { error in
            guard case .hostTooOld(let plugin, let required, let current)? = error as? PluginError else {
                return XCTFail("应该报宿主版本过低，实际是 \(error)")
            }
            XCTAssertEqual(plugin, "future")
            XCTAssertEqual(required, "99.0.0")
            XCTAssertEqual(current, PluginImporter.hostVersion.display)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pluginsDir.appendingPathComponent("future").path), "拒绝后不能留下插件目录")
    }

    /// 报错文案要能直接给用户看：说清要哪个版本、现在是什么版本
    func testHostTooOldMessageIsReadable() {
        let e = PluginError.hostTooOld(plugin: "future", required: "1.2.0", current: "0.1.0")
        let msg = e.errorDescription ?? ""
        XCTAssertTrue(msg.contains("1.2.0"), "要写清需要的版本：\(msg)")
        XCTAssertTrue(msg.contains("0.1.0"), "要写清当前版本：\(msg)")
    }

    /// minHostVersion 没写 / 写成乱七八糟的东西 → 都退回默认值，不误伤插件
    func testRequiredHostVersionFallsBackToDefault() {
        XCTAssertEqual(PluginImporter.requiredHostVersion(of: [:]), PluginImporter.defaultMinHostVersion)
        XCTAssertEqual(PluginImporter.requiredHostVersion(of: ["minHostVersion": ""]),
                       PluginImporter.defaultMinHostVersion)
        XCTAssertEqual(PluginImporter.requiredHostVersion(of: ["minHostVersion": "abc"]),
                       PluginImporter.defaultMinHostVersion)
        XCTAssertEqual(PluginImporter.requiredHostVersion(of: ["minHostVersion": "1.2"]),
                       PluginVersion(raw: "1.2"))
    }
}
