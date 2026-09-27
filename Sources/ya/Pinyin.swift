import Foundation

/// 汉字 → 拼音（全拼 / 首字母）转换与模糊匹配
/// 从 AppSearcher 抽出，供应用搜索与插件搜索共用
enum Pinyin {
    /// "腾讯会议 Tencent" -> full: "tengxunhuiyitencent", initials: "txht"
    static func transform(_ text: String) -> (full: String, initials: String) {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let withSpaces = (mutable as String).lowercased()

        var fullChars: [Character] = []
        var initialsChars: [Character] = []
        var atWordStart = true
        for ch in withSpaces {
            guard ch.isLetter || ch.isNumber else {
                atWordStart = true // 空格/符号视为分词边界
                continue
            }
            // 转写后中文已变成 ASCII 拼音字母，其余非 ASCII（如日文）直接忽略
            guard ch.isASCII else { continue }
            fullChars.append(ch)
            if atWordStart { initialsChars.append(ch); atWordStart = false }
        }
        return (String(fullChars), String(initialsChars))
    }

    /// q 是否为 s 的子序列（模糊首字母匹配：txhy / txy / th 都能命中 txhy）
    static func isSubsequence(_ q: String, _ s: String) -> Bool {
        guard !q.isEmpty, !s.isEmpty else { return false }
        var idx = s.startIndex
        for ch in q {
            guard idx < s.endIndex,
                  let found = s[idx...].firstIndex(of: ch) else { return false }
            idx = s.index(after: found)
        }
        return true
    }
}
