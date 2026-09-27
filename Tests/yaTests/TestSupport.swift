import Foundation
import XCTest
@testable import yaCore

/// 单测公共底座。
///
/// 关键：`AppPaths.rootOverride` / `AppResources.webRootOverride` 让所有磁盘读写
/// 落到临时目录，测试结束后复位 —— 否则单测会读到（甚至改掉）真实的用户数据。
class YaTestCase: XCTestCase {
    /// 本次测试独占的临时根目录
    var tmp: URL!
    /// 插件目录（对应 AppPaths.plugins）
    var pluginsDir: URL!
    /// 内置插件目录（对应 AppResources.webRoot/plugins）
    var builtinDir: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ya-test-\(UUID().uuidString)", isDirectory: true)
        pluginsDir = tmp.appendingPathComponent("plugins", isDirectory: true)
        builtinDir = tmp.appendingPathComponent("builtin/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: builtinDir, withIntermediateDirectories: true)

        AppPaths.rootOverride = tmp
        AppResources.webRootOverride = tmp.appendingPathComponent("builtin", isDirectory: true)
        PluginIndexOverrides.reset()
    }

    override func tearDown() {
        AppPaths.rootOverride = nil
        AppResources.webRootOverride = nil
        PluginIndexOverrides.reset()
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - 夹具

    /// 在插件目录里放一个插件
    @discardableResult
    func makePlugin(_ id: String,
                    manifest: [String: Any],
                    in dir: URL? = nil) throws -> URL {
        let root = (dir ?? pluginsDir!).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: root.appendingPathComponent("plugin.json"))
        return root
    }

    /// 最小可用插件：只声明主关键字
    @discardableResult
    func makeSimplePlugin(_ id: String,
                          keyword: String,
                          aliases: [String] = [],
                          version: String = "1.0.0",
                          features: [[String: Any]] = [],
                          in dir: URL? = nil) throws -> URL {
        var manifest: [String: Any] = ["keyword": keyword, "version": version]
        if !aliases.isEmpty { manifest["keywords"] = aliases }
        if !features.isEmpty { manifest["features"] = features }
        return try makePlugin(id, manifest: manifest, in: dir)
    }

    func writeFile(_ name: String, _ content: String, in dir: URL) throws {
        try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func contents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// PluginIndex 的覆盖表落在 AppPaths 下，测试之间要清干净，否则会串味
enum PluginIndexOverrides {
    static func reset() {
        let url = AppPaths.file("keyword-overrides.json")
        try? FileManager.default.removeItem(at: url)
        PluginIndex.shared.reloadOverrides()
    }
}

/// 断言两个 Any 字典“打印出来一样”，失败信息比直接比较 Any 可读得多
func XCTAssertEqualJSON(_ a: [String: Any],
                        _ b: [String: Any],
                        file: StaticString = #filePath,
                        line: UInt = #line) {
    let sa = SafeJSON.string(a)
    let sb = SafeJSON.string(b)
    XCTAssertEqual(sa, sb, file: file, line: line)
}
