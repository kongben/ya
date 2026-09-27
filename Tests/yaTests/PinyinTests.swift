import XCTest
@testable import yaCore

/// 汉字 → 拼音。搜索能不能用全拼/首字母命中应用与插件，全靠这里
final class PinyinTests: XCTestCase {

    func testChineseFullAndInitials() {
        let r = Pinyin.transform("腾讯会议")
        XCTAssertEqual(r.full, "tengxunhuiyi")
        XCTAssertEqual(r.initials, "txhy")
    }

    /// 中英混排：英文部分照抄，且各自成词（首字母都要取到）
    func testMixedChineseEnglish() {
        let r = Pinyin.transform("腾讯会议 Tencent")
        XCTAssertEqual(r.full, "tengxunhuiyitencent")
        XCTAssertEqual(r.initials, "txhyt")
    }

    /// 纯英文：一个连续单词只有一个首字母
    func testPureEnglish() {
        XCTAssertEqual(Pinyin.transform("Hello").full, "hello")
        XCTAssertEqual(Pinyin.transform("Hello").initials, "h")
        XCTAssertEqual(Pinyin.transform("Hello World").full, "helloworld")
        XCTAssertEqual(Pinyin.transform("Hello World").initials, "hw")
    }

    /// 空格/符号是分词边界，数字保留，其它非 ASCII（日文假名）忽略
    func testSeparatorsAndDigits() {
        // 注意：任何非字母数字字符（包括 "."）都会重置「词首」标记，
        // 所以 "2.0" 的 2 和 0 都算首字母
        let r = Pinyin.transform("微信 2.0")
        XCTAssertEqual(r.full, "weixin20")
        XCTAssertEqual(r.initials, "wx20")
        let jp = Pinyin.transform("カレンダー")
        XCTAssertTrue(jp.full.isEmpty, "日文没有拼音转写，应被忽略而不是留下假名")
    }

    func testEmpty() {
        let r = Pinyin.transform("")
        XCTAssertEqual(r.full, "")
        XCTAssertEqual(r.initials, "")
    }

    // MARK: - 模糊子序列

    func testSubsequence() {
        XCTAssertTrue(Pinyin.isSubsequence("txhy", "txhy"))
        XCTAssertTrue(Pinyin.isSubsequence("th", "txhy"))   // 跳着命中
        XCTAssertTrue(Pinyin.isSubsequence("t", "txhy"))
        XCTAssertFalse(Pinyin.isSubsequence("yt", "txhy"))  // 顺序不对
        XCTAssertFalse(Pinyin.isSubsequence("txhyz", "txhy"))
    }

    func testSubsequenceEdgeCases() {
        XCTAssertFalse(Pinyin.isSubsequence("", "txhy"), "空查询不参与匹配")
        XCTAssertFalse(Pinyin.isSubsequence("a", ""))
        XCTAssertFalse(Pinyin.isSubsequence("", ""))
    }
}
