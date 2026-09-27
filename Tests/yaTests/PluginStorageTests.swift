import XCTest
@testable import yaCore

/// 插件 KV 存储（api.db）。每个插件一个 json，落在 storage/ 下
final class PluginStorageTests: YaTestCase {
    private var storage: PluginStorage!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = tmp.appendingPathComponent("storage", isDirectory: true)
        storage = PluginStorage(dir: dir)
    }

    override func tearDown() {
        storage = nil
        super.tearDown()
    }

    func testSetGetRemove() {
        XCTAssertEqual(storage.get(plugin: "qrcode", key: "history"), "", "没写过的 key 返回空串")
        storage.set(plugin: "qrcode", key: "history", value: "abc")
        XCTAssertEqual(storage.get(plugin: "qrcode", key: "history"), "abc")
        storage.remove(plugin: "qrcode", key: "history")
        XCTAssertEqual(storage.get(plugin: "qrcode", key: "history"), "")
    }

    func testNamespacesAreIsolated() {
        storage.set(plugin: "a", key: "k", value: "1")
        storage.set(plugin: "b", key: "k", value: "2")
        XCTAssertEqual(storage.get(plugin: "a", key: "k"), "1")
        XCTAssertEqual(storage.get(plugin: "b", key: "k"), "2")
    }

    func testPersistsAcrossInstances() {
        storage.set(plugin: "qrcode", key: "history", value: "[1,2]")
        XCTAssertEqual(PluginStorage(dir: dir).get(plugin: "qrcode", key: "history"), "[1,2]")
    }

    /// 插件 id 来自外部，文件名必须消毒，否则 ".."/"/" 会写到别的目录去
    func testPluginIdIsSanitizedForFilename() {
        storage.set(plugin: "../evil", key: "k", value: "v")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent()
            .appendingPathComponent("evil.json").path),
            "不能写到 storage/ 之外")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil.json").path))
        XCTAssertEqual(storage.get(plugin: "../evil", key: "k"), "v")
    }

    func testEmptyPluginIdFallsBackToGlobal() {
        storage.set(plugin: "!!!", key: "k", value: "v")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("global.json").path))
    }

    /// 插件存的东西可能有换行/引号/Emoji，不能把 json 写坏
    func testSpecialCharactersRoundTrip() {
        let value = "line1\nline2 \"quo\" \\ 🎉"
        storage.set(plugin: "qrcode", key: "h", value: value)
        XCTAssertEqual(storage.get(plugin: "qrcode", key: "h"), value)
    }
}
