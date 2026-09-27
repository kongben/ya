import Foundation
import XCTest
@testable import yaCore

/// 日志是诊断的地基：崩溃时磁盘往往来不及 flush，能拿到的只有内存缓冲那几百行。
/// 所以这里重点验「缓冲能取回来」而不是「stdout 打出了什么」。
final class LogTests: YaTestCase {
    override func setUp() {
        super.setUp()
        Log.reset()
    }

    override func tearDown() {
        Log.reset()
        super.tearDown()
    }

    func testSnapshotContainsRecentLines() {
        Log.info("第一条")
        Log.info("第二条")
        let snap = Log.snapshot()
        XCTAssertTrue(snap.contains("第一条"))
        XCTAssertTrue(snap.contains("第二条"))
        XCTAssertEqual(Log.count, 2)
    }

    /// 每行都要有时间和级别，否则拿到一堆裸文本也没法判断先后顺序
    func testLineHasTimestampAndLevel() {
        Log.warn("带级别的一行")
        let line = Log.snapshot().split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(line.contains("[WARN]"), "实际: \(line)")
        XCTAssertTrue(line.contains("带级别的一行"))
        // 2026-09-26 04:20:31.123 这种格式，用正则卡一下开头的日期时间
        let range = line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[(INFO|WARN|ERROR|CRASH)\]"#,
                               options: .regularExpression)
        XCTAssertNotNil(range, "行首应是时间戳 + 级别，实际: \(line)")
    }

    func testSnapshotLimitKeepsTheNewest() {
        for i in 1...10 { Log.info("行\(i)") }
        let last3 = Log.snapshot(limit: 3)
        XCTAssertEqual(last3.split(separator: "\n").count, 3)
        XCTAssertTrue(last3.contains("行10"))
        XCTAssertTrue(last3.contains("行8"))
        XCTAssertFalse(last3.contains("行7"), "超出 limit 的旧行不该出现")
    }

    /// 缓冲是环形的：写超容量后老的被丢掉，但总量不能无限涨
    func testRingBufferDropsOldestBeyondCapacity() {
        for i in 0..<(Log.capacity + 50) { Log.info("行\(i)") }
        XCTAssertEqual(Log.count, Log.capacity)
        let snap = Log.snapshot()
        XCTAssertTrue(snap.contains("行\(Log.capacity + 49)"), "最新的要留着")
        XCTAssertFalse(snap.contains("行0 "), "最旧的应被挤掉")
    }

    func testCrashLevelIsRecorded() {
        Log.crash("模拟崩溃")
        XCTAssertTrue(Log.snapshot().contains("[CRASH] 模拟崩溃"))
    }

    func testResetClearsBuffer() {
        Log.info("abc")
        Log.reset()
        XCTAssertEqual(Log.count, 0)
        XCTAssertTrue(Log.snapshot().isEmpty)
    }

    /// 落盘：诊断导出要带日志文件，写不出来等于没有
    func testWritesToLogFile() {
        Log.info("落盘一行")
        let text = contents(Log.fileURL)
        XCTAssertTrue(text.contains("落盘一行"), "日志应写进 \(Log.fileURL.path)，实际内容: \(text)")
    }

    /// 关掉落盘后不该再写文件（单测默认就靠这个不污染用户目录）
    func testFileDisabledSkipsDiskWrite() {
        let previous = Log.fileEnabled
        Log.fileEnabled = false
        Log.reset()
        let existed = FileManager.default.fileExists(atPath: Log.fileURL.path)
        XCTAssertFalse(existed, "关掉落盘且 reset 后不该出现日志文件")
        Log.fileEnabled = previous
    }

    /// 追加而不是覆盖：连续两行都要在文件里
    func testAppendsInsteadOfOverwriting() {
        Log.info("A")
        Log.info("B")
        let text = contents(Log.fileURL)
        XCTAssertTrue(text.contains("[INFO] A"))
        XCTAssertTrue(text.contains("[INFO] B"))
    }
}
