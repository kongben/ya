import Foundation
import Darwin

/// 本机网卡上正在用的 IP 列表（给插件用）。
///
/// 为什么要有它：插件跑在 WKWebView 里，拿不到网卡信息；而「本地起的服务用什么 IP 访问」
/// 又必须问本机——每天的办公网 IP 都不一样，写死在配置里第二天就失效。
///
/// 这里只负责**如实枚举**（接口名 + 地址 + ipv4/ipv6），不选优：
/// 选哪个是插件的策略（见 h5-service 的 pickIp），改策略不用动宿主。
enum LocalIPs {
    struct Entry {
        let interface: String
        let address: String
        /// "ipv4" / "ipv6"
        let family: String
    }

    /// 只收 UP + RUNNING 且非回环的地址；IPv6 的临时地址（如 fe80::）会一并给出，
    /// 由调用方按自己的规则过滤
    static func current() -> [Entry] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var out: [Entry] = []
        var cursor = head
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0,
                  flags & Int32(IFF_RUNNING) != 0,
                  flags & Int32(IFF_LOOPBACK) == 0,
                  let addr = p.pointee.ifa_addr else { continue }

            let family = Int32(addr.pointee.sa_family)
            var len: socklen_t
            var kind: String
            switch family {
            case AF_INET:
                len = socklen_t(MemoryLayout<sockaddr_in>.size)
                kind = "ipv4"
            case AF_INET6:
                len = socklen_t(MemoryLayout<sockaddr_in6>.size)
                kind = "ipv6"
            default:
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.isEmpty else { continue }
            out.append(Entry(interface: String(cString: p.pointee.ifa_name), address: text, family: kind))
        }
        // 同一网卡可能有多个地址，按接口名排序让结果稳定（en0 在 en1 之前）
        return out.sorted { a, b in
            a.interface == b.interface ? a.address < b.address : a.interface < b.interface
        }
    }

    /// 给 JS 的结构：[[String: Any]] 直接走 SafeJSON
    static func payload() -> [[String: Any]] {
        current().map { ["interface": $0.interface, "address": $0.address, "family": $0.family] }
    }
}
