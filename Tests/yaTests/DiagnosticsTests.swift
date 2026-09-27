import Foundation
import XCTest
@testable import yaCore

/// 诊断模块：核心是「上次是不是异常退出」和「导出文件里有没有该有的东西」。
/// 这两件事决定了内测用户报障时能不能拿到有效信息。
final class DiagnosticsTests: YaTestCase {
    override func setUp() {
        super.setUp()
        Log.reset()
    }

    override func tearDown() {
        Log.reset()
        super.tearDown()
    }

    // MARK: - 上次退出是否异常

    /// 全新安装（没有标记文件）不该被判成"上次崩了"，否则每次启动都误报
    func testNoMarkerMeansNotAbnormal() {
        XCTAssertFalse(Diagnostics.previousLaunchWasAbnormal())
    }

    /// 走完 launch → 正常退出 → 下次启动，应判为正常
    func testCleanExitIsRecorded() {
        Diagnostics.markLaunch()
        XCTAssertTrue(Diagnostics.previousLaunchWasAbnormal(), "刚启动还没退出，标记应为未正常退出")
        Diagnostics.markCleanExit()
        XCTAssertFalse(Diagnostics.previousLaunchWasAbnormal())
    }

    /// 崩溃场景：启动后直接"再来一次"（没走 cleanExit），此时必须报异常
    func testCrashIsDetectedOnNextLaunch() {
        Diagnostics.markLaunch()
        // 模拟进程被杀：什么都没做，直接进入下一次启动
        XCTAssertTrue(Diagnostics.previousLaunchWasAbnormal(), "上次没走到正常退出，必须能发现")
    }

    func testMarkerKeepsVersionAndPid() throws {
        Diagnostics.markLaunch()
        let data = try Data(contentsOf: AppPaths.file("last-launch.json"))
        let marker = try JSONDecoder().decode(Diagnostics.LaunchMarker.self, from: data)
        XCTAssertFalse(marker.cleanExit)
        XCTAssertEqual(marker.version, NativeServices.appVersion)
        XCTAssertEqual(marker.pid, ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - 报告内容

    func testReportHasRuntimeAndDataSections() {
        let text = Diagnostics.collect()
        XCTAssertTrue(text.contains("ya 诊断报告"))
        XCTAssertTrue(text.contains("[运行环境]"))
        XCTAssertTrue(text.contains("ya 版本: \(NativeServices.appVersion)"))
        XCTAssertTrue(text.contains("[数据目录]"))
        XCTAssertTrue(text.contains("[已安装插件]"))
        XCTAssertTrue(text.contains("[关键字冲突]"))
        XCTAssertTrue(text.contains("[上次退出]"))
    }

    func testReportListsPluginsWithKeywords() throws {
        try makeSimplePlugin("qrcode", keyword: "qr", aliases: ["ewm"], version: "1.2.0")
        let text = Diagnostics.collect()
        XCTAssertTrue(text.contains("- qrcode v1.2.0"), "插件 id 与版本要能一眼看到，实际:\n\(text)")
        XCTAssertTrue(text.contains("关键字: qr, ewm"), "实际:\n\(text)")
    }

    /// 没有任何插件时要写「（无）」而不是留一个空章节——空着会让人以为漏采了
    func testReportShowsPlaceholderForEmptyPluginList() {
        XCTAssertTrue(Diagnostics.collect().contains("（无）"))
    }

    func testReportShowsKeywordConflicts() throws {
        // 两个插件争同一个关键字：b 后装，主关键字被 a 抢走
        try makeSimplePlugin("alpha", keyword: "dup")
        try makeSimplePlugin("beta", keyword: "dup")
        let text = Diagnostics.collect()
        XCTAssertTrue(text.contains("[关键字冲突]"))
        XCTAssertTrue(text.contains("被抢占") || text.contains("被"), "冲突信息要出现在报告里，实际:\n\(text)")
    }

    // MARK: - 导出

    func testExportWritesReportAndLog() throws {
        Log.info("导出前的一行日志")
        let dest = tmp.appendingPathComponent("diag.txt")
        try Diagnostics.export(to: dest)
        let text = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(text.contains("ya 诊断报告"))
        XCTAssertTrue(text.contains("[最近日志]"))
        XCTAssertTrue(text.contains("导出前的一行日志"), "日志要跟着一起出去，否则等于没带现场")
    }

    /// 导出失败要抛出来（UI 层靠它弹提示），不能静默吞掉
    func testExportToBadPathThrows() {
        let impossible = URL(fileURLWithPath: "/dev/null/impossible/diag.txt")
        XCTAssertThrowsError(try Diagnostics.export(to: impossible))
    }

    func testDefaultFileNameFormat() {
        let name = Diagnostics.defaultFileName()
        let ok = name.range(of: #"^ya-diagnostics-\d{8}-\d{6}\.txt$"#, options: .regularExpression)
        XCTAssertNotNil(ok, "文件名应带时间戳且以 .txt 结尾，实际: \(name)")
    }
}
