import XCTest
import Darwin
@testable import yaCore

/// 本机 IP 枚举：给插件用的是「接口名 + 地址 + ipv4/ipv6」，选优交给插件。
/// 不断言具体 IP（每台机器、每次联网都不一样），只保证枚举出来的东西是干净合法的。
final class LocalIPsTests: XCTestCase {
    func testEntriesAreWellFormed() {
        for e in LocalIPs.current() {
            XCTAssertFalse(e.interface.isEmpty)
            XCTAssertFalse(e.address.isEmpty)
            XCTAssertTrue(e.family == "ipv4" || e.family == "ipv6", "family 只能是 ipv4/ipv6，实际 \(e.family)")
            XCTAssertTrue(isValidIP(e.address, v4: e.family == "ipv4"), "地址不合法: \(e.address)")
        }
    }

    func testLoopbackIsFilteredOut() {
        let addrs = LocalIPs.current().map { $0.address }
        XCTAssertFalse(addrs.contains("127.0.0.1"), "回环地址不该出现在列表里")
        XCTAssertFalse(addrs.contains("::1"))
        XCTAssertFalse(addrs.contains { $0.hasPrefix("fe80") && $0.contains("%lo") })
    }

    func testPayloadHasAllKeys() {
        for item in LocalIPs.payload() {
            XCTAssertNotNil(item["interface"] as? String)
            XCTAssertNotNil(item["address"] as? String)
            XCTAssertNotNil(item["family"] as? String)
        }
    }

    private func isValidIP(_ text: String, v4: Bool) -> Bool {
        // IPv6 带作用域后缀（fe80::1%en0）也要算合法，先剥掉
        let addr = text.components(separatedBy: "%").first ?? text
        var buf = [UInt8](repeating: 0, count: 16)
        return inet_pton(v4 ? AF_INET : AF_INET6, addr, &buf) == 1
    }
}
