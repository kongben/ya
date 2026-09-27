import Foundation

/// 插件版本号。宽松解析语义化版本：`1` / `1.2` / `1.2.3` / `v1.2.3-beta` 都能比较。
///
/// 只比较数字段：缺失的段按 0 处理（`1.2` == `1.2.0`），
/// 预发布后缀（`-beta.1`）与构建元数据（`+build`）不参与比较——
/// 插件生态里更多是"数字变大了就是新版本"，严格 SemVer 反而会把 `1.2.0-beta` 判成比 `1.2.0` 旧。
struct PluginVersion: Equatable, Comparable, CustomStringConvertible {
    /// 数字段，如 "1.2.3" → [1, 2, 3]
    let parts: [Int]
    /// 原始字符串，用于展示（缺失时为 ""）
    let raw: String

    static let zero = PluginVersion(raw: "")

    init(raw: String) {
        self.raw = raw
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        for sep in ["-", "+"] {
            if let i = s.firstIndex(of: Character(sep)) { s = String(s[s.startIndex..<i]) }
        }
        // 非数字段直接丢弃（"1.x" → [1]），宁可少比一位也不要解析失败
        parts = s.split(separator: ".").compactMap { Int($0) }
    }

    /// 未声明版本时为 nil，方便"有没有版本"和"版本是多少"区分开
    var isEmpty: Bool { raw.isEmpty }

    /// 展示用：没声明版本时给一个占位符
    var display: String { raw.isEmpty ? "—" : raw }

    var description: String { display }

    /// 全 0（未声明 / 解析不出数字）视为"没有版本"，不参与升级判断
    var isUnknown: Bool { parts.isEmpty || parts.allSatisfy { $0 == 0 } }

    static func < (lhs: PluginVersion, rhs: PluginVersion) -> Bool {
        let n = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<n {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    static func == (lhs: PluginVersion, rhs: PluginVersion) -> Bool {
        let n = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<n {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return false }
        }
        return true
    }
}
