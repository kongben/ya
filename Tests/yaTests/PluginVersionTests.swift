import XCTest
@testable import yaCore

/// 版本号解析与比较。"1.10 比 1.9 新" 这种判断错了，插件升级就会来回降级
final class PluginVersionTests: XCTestCase {

    func testParse() {
        XCTAssertEqual(PluginVersion(raw: "1.2.3").parts, [1, 2, 3])
        XCTAssertEqual(PluginVersion(raw: "1").parts, [1])
        XCTAssertEqual(PluginVersion(raw: "1.2").parts, [1, 2])
        XCTAssertEqual(PluginVersion(raw: "v2.0").parts, [2, 0], "v 前缀要吃掉")
        XCTAssertEqual(PluginVersion(raw: "  1.4  ").parts, [1, 4], "首尾空白要去掉")
    }

    /// 非数字段直接丢弃：宁可少比一位，也不要解析失败
    func testParseIgnoresNonNumeric() {
        XCTAssertEqual(PluginVersion(raw: "1.x").parts, [1])
        XCTAssertEqual(PluginVersion(raw: "1.2.3-beta.1").parts, [1, 2, 3], "预发布后缀不参与比较")
        XCTAssertEqual(PluginVersion(raw: "1.2.3+build9").parts, [1, 2, 3], "构建元数据不参与比较")
        XCTAssertEqual(PluginVersion(raw: "abc").parts, [])
    }

    func testCompare() {
        XCTAssertTrue(PluginVersion(raw: "1.10") > PluginVersion(raw: "1.9"), "按数字比，不是按字符串")
        XCTAssertTrue(PluginVersion(raw: "2") > PluginVersion(raw: "1.9.9"))
        XCTAssertTrue(PluginVersion(raw: "1.0.1") > PluginVersion(raw: "1.0"))
        XCTAssertTrue(PluginVersion(raw: "1.2") == PluginVersion(raw: "1.2.0"), "缺失的段按 0")
        XCTAssertTrue(PluginVersion(raw: "1.2.0") == PluginVersion(raw: "1.2.0-beta"), "后缀不影响")
        XCTAssertFalse(PluginVersion(raw: "1.2.0") < PluginVersion(raw: "1.2.0"))
    }

    func testUnknownAndDisplay() {
        XCTAssertTrue(PluginVersion.zero.isUnknown)
        XCTAssertTrue(PluginVersion(raw: "").isUnknown)
        XCTAssertTrue(PluginVersion(raw: "0.0.0").isUnknown)
        XCTAssertTrue(PluginVersion(raw: "abc").isUnknown)
        XCTAssertFalse(PluginVersion(raw: "0.0.1").isUnknown)

        XCTAssertTrue(PluginVersion.zero.isEmpty)
        XCTAssertEqual(PluginVersion.zero.display, "—", "没声明版本时给占位符")
        XCTAssertEqual(PluginVersion(raw: "1.2.3").display, "1.2.3")
    }

    /// 版本变化描述：插件管理页与深链安装都拿它告诉用户装了新版还是旧版
    func testImportResultKind() {
        let first = PluginImportResult(id: "demo", newVersion: PluginVersion(raw: "1.0.0"), oldVersion: nil)
        XCTAssertEqual(first.kind, PluginImportResult.Kind.installed)
        XCTAssertEqual(first.versionChange, "1.0.0")

        let up = PluginImportResult(id: "demo", newVersion: .init(raw: "1.2.0"), oldVersion: .init(raw: "1.0.0"))
        XCTAssertEqual(up.kind, PluginImportResult.Kind.updated)
        XCTAssertEqual(up.versionChange, "1.0.0 → 1.2.0")

        let down = PluginImportResult(id: "demo", newVersion: .init(raw: "1.0.0"), oldVersion: .init(raw: "1.2.0"))
        XCTAssertEqual(down.kind, PluginImportResult.Kind.downgraded)

        let same = PluginImportResult(id: "demo", newVersion: .init(raw: "1.0.0"), oldVersion: .init(raw: "1.0.0"))
        XCTAssertEqual(same.kind, PluginImportResult.Kind.reinstalled)
    }

}
