import XCTest
@testable import yaCore

/// SafeJSON 存在的唯一理由：JSONSerialization 对某些字符串会抛 **ObjC 异常**，
/// 而 Swift 的 try? 挡不住 → 进程直接 SIGABRT。这里手写序列化必须 100% 不抛。
final class SafeJSONTests: XCTestCase {

    func testScalars() {
        XCTAssertEqual(SafeJSON.string("abc"), "\"abc\"")
        XCTAssertEqual(SafeJSON.string(true), "true")
        XCTAssertEqual(SafeJSON.string(false), "false")
        XCTAssertEqual(SafeJSON.string(42), "42")
        XCTAssertEqual(SafeJSON.string(NSNull()), "null")
    }

    func testEscaping() {
        XCTAssertEqual(SafeJSON.string("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(SafeJSON.string("a\\b"), "\"a\\\\b\"")
        XCTAssertEqual(SafeJSON.string("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(SafeJSON.string("a\rb"), "\"a\\rb\"")
        XCTAssertEqual(SafeJSON.string("a\tb"), "\"a\\tb\"")
        // 控制字符必须转成 \uXXXX，直接塞进字符串是非法 JSON
        XCTAssertEqual(SafeJSON.string("a\u{01}b"), "\"a\\u0001b\"")
        XCTAssertEqual(SafeJSON.string("a\u{7F}b"), "\"a\\u007fb\"")
    }

    /// 剪贴板里可能带 Emoji / 中日韩字符，不能崩也不能乱码
    func testUnicodePassThrough() {
        let s = "你好 🎉 zh"
        let json = SafeJSON.string(s)
        XCTAssertTrue(json.contains("你好"))
        XCTAssertTrue(json.contains("🎉"))
        XCTAssertEqual(roundTrip(json), s)
    }

    /// NaN / Infinity 不是合法 JSON，必须输出 null（否则 WebView 解析直接失败）
    func testNonFiniteNumbers() {
        XCTAssertEqual(SafeJSON.string(Double.nan), "null")
        XCTAssertEqual(SafeJSON.string(Double.infinity), "null")
        XCTAssertEqual(SafeJSON.string(-Double.infinity), "null")
        XCTAssertEqual(SafeJSON.string(1.5), "1.5")
    }

    func testNestedContainers() {
        XCTAssertEqual(SafeJSON.string([1, "a", true] as [Any]), "[1,\"a\",true]")
        XCTAssertEqual(SafeJSON.string([] as [Any]), "[]")
        let dict: [String: Any] = ["a": 1, "b": ["c" as Any]]
        // 字典遍历顺序不保证，比对解析结果而不是字符串
        let parsed = try? JSONSerialization.jsonObject(with: SafeJSON.string(dict).data(using: .utf8)!)
            as? [String: Any]
        XCTAssertEqual(parsed?["a"] as? Int, 1)
        XCTAssertEqual(parsed?["b"] as? [String], ["c"])
    }

    func testUnknownTypeBecomesNull() {
        XCTAssertEqual(SafeJSON.string(NSObject()), "null")
    }

    /// 插件存储专用：[String: String]
    func testObject() {
        XCTAssertEqual(SafeJSON.object([:]), "{}")
        let json = SafeJSON.object(["k": "v"])
        XCTAssertEqual(json, "{\"k\":\"v\"}")
        XCTAssertEqual(SafeJSON.object(["a\"b": "c\nd"]), "{\"a\\\"b\":\"c\\nd\"}")
    }

    func testDataIsUTF8() {
        let data = SafeJSON.data(["a": 1] as [String: Any])
        XCTAssertNotNil(data)
        XCTAssertEqual(String(data: data!, encoding: .utf8), "{\"a\":1}")
    }

    // MARK: - 私有

    private func roundTrip(_ json: String) -> String? {
        guard let d = json.data(using: .utf8),
              let v = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)
        else { return nil }
        return v as? String
    }
}
