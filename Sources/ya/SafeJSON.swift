import Foundation

/// 绝不抛异常的 JSON 序列化器
///
/// 为什么不用 `JSONSerialization.data(withJSONObject:)`：
/// 它对某些字符串（如剪贴板里含非法 Unicode 的内容）会抛 **Objective-C 异常**，
/// 而 Swift 的 `try?` 只能捕获 Swift 错误、挡不住 ObjC 异常 → 进程直接 SIGABRT 闪退。
/// 桥接数据只含 String / Bool / Int / Double / 数组 / 字典，这里手写序列化即可 100% 安全。
enum SafeJSON {
    static func string(_ value: Any) -> String {
        switch value {
        case let s as String: return quote(s)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double:
            // NaN / Infinity 不是合法 JSON，输出 null
            return d.isFinite ? String(d) : "null"
        case is NSNull: return "null"
        case let n as NSNumber:
            // Bool 已被上面的分支接住（Swift Bool 桥接优先），这里兜底处理数值
            return n.doubleValue.isFinite ? String(n.doubleValue) : "null"
        case let arr as [Any]:
            return "[" + arr.map(string).joined(separator: ",") + "]"
        case let dict as [String: Any]:
            let items = dict.map { quote($0.key) + ":" + string($0.value) }
            return "{" + items.joined(separator: ",") + "}"
        default:
            return "null"
        }
    }

    /// 落盘用：直接拿 Data，省掉调用方各自 `string(v).data(using: .utf8)`
    static func data(_ value: Any) -> Data? { string(value).data(using: .utf8) }

    /// [String: String] 专用（插件存储写入）
    static func object(_ dict: [String: String]) -> String {
        let items = dict.map { quote($0.key) + ":" + quote($0.value) }
        return "{" + items.joined(separator: ",") + "}"
    }

    private static func quote(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.unicodeScalars.count + 2)
        out.append("\"")
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    // Swift String 只含合法 Unicode 标量，不会有孤立代理项
                    out.append(Character(scalar))
                }
            }
        }
        out.append("\"")
        return out
    }
}
