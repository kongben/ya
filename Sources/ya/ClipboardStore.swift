import Foundation

/// 剪贴板历史条目
struct ClipItem {
    enum Kind: String { case text, image, file }
    let id: String
    let kind: Kind
    /// 文本内容；file 类型这里存换行的路径列表（也方便直接复制）
    let text: String
    /// 文件/文件夹路径（只有 file 类型非空）
    let paths: [String]
    let timestamp: TimeInterval
    var pinned: Bool
    /// 是否落了缩略图（image 类型为真，file 类型当图片文件时也为真）
    var hasImage: Bool

    var dict: [String: Any] {
        [
            "id": id,
            "kind": kind.rawValue,
            "text": text,
            "paths": paths,
            "timestamp": timestamp,
            "pinned": pinned,
            "hasImage": hasImage,
        ]
    }

    static func from(_ d: [String: Any]) -> ClipItem? {
        guard let id = d["id"] as? String,
              let rawKind = d["kind"] as? String,
              let kind = Kind(rawValue: rawKind) else { return nil }
        return ClipItem(
            id: id,
            kind: kind,
            text: d["text"] as? String ?? "",
            paths: d["paths"] as? [String] ?? [],
            timestamp: d["timestamp"] as? TimeInterval ?? 0,
            pinned: d["pinned"] as? Bool ?? false,
            hasImage: d["hasImage"] as? Bool ?? false
        )
    }
}

/// 剪贴板历史的**纯数据层**：只管「条目怎么排、怎么去重、超上限怎么裁」。
///
/// 为什么从 ClipboardManager 里抽出来：后者同时干着轮询 NSPasteboard、写缩略图、
/// 读写磁盘三件事，想验证「去重会不会把收藏项挤掉」「裁剪会不会删到收藏项」
/// 就必须先造一个真的剪贴板。抽成这个不依赖 AppKit 的结构体之后，
/// 这些规则可以直接用 XCTest 断言（见 Tests/yaTests/ClipboardStoreTests.swift）。
///
/// 所有会删条目的操作都**返回被删掉的 id**，由调用方去删对应的缩略图文件 ——
/// 数据层不碰磁盘。
struct ClipboardStore {
    private(set) var items: [ClipItem] = []

    // MARK: - 写入

    /// 插入一条（文本 / 文件）：先挤掉同内容的未收藏旧条目，再放到最前。
    /// - Returns: `inserted` 是否真的插进去了（内容与首条完全一样时为 false）；
    ///            `evicted` 本次被裁掉、需要删除缩略图的 id。
    @discardableResult
    mutating func insert(_ item: ClipItem, limit: Int) -> (inserted: Bool, evicted: [String]) {
        items.removeAll { $0.kind == item.kind && $0.text == item.text && !$0.pinned }
        // 走到这里还剩下同内容的，只能是收藏项；它已经在最前面就不必再插一条
        if items.first?.kind == item.kind && items.first?.text == item.text {
            return (false, [])
        }
        items.insert(item, at: 0)
        return (true, trim(limit: limit))
    }

    /// 追加一条（图片）：**不去重** —— 图片条目 text 恒为空串，
    /// 一旦去重，连续截两张图就只会剩最后一张。
    /// - Returns: 被裁掉、需要删除缩略图的 id
    @discardableResult
    mutating func append(_ item: ClipItem, limit: Int) -> [String] {
        items.insert(item, at: 0)
        return trim(limit: limit)
    }

    /// 数量超限就丢最旧的未收藏项
    /// - Returns: 被删掉的 id
    @discardableResult
    mutating func trim(limit: Int) -> [String] {
        guard items.count > limit else { return [] }
        var overflow = items.count - limit
        var removed: [String] = []
        for i in stride(from: items.count - 1, through: 0, by: -1) where overflow > 0 {
            if items[i].pinned { continue }
            removed.append(items.remove(at: i).id)
            overflow -= 1
        }
        return removed
    }

    // MARK: - 操作

    @discardableResult
    mutating func togglePin(id: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        items[idx].pinned.toggle()
        sort()
        return true
    }

    /// - Returns: 被删掉的 id（没找到则为 nil）
    @discardableResult
    mutating func remove(id: String) -> String? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: idx).id
    }

    /// 清空；默认保留收藏项
    /// - Returns: 被清掉的 id
    @discardableResult
    mutating func clear(keepingPinned: Bool = true) -> [String] {
        let removed = keepingPinned ? items.filter { !$0.pinned } : items
        items = keepingPinned ? items.filter { $0.pinned } : []
        return removed.map(\.id)
    }

    /// 收藏在前，其余按时间倒序
    mutating func sort() {
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.timestamp > b.timestamp
        }
    }

    /// 磁盘载入后整体换入（同时修正 hasImage）
    mutating func replaceAll(_ loaded: [ClipItem], existingImageIDs: Set<String> = []) {
        var fixed = loaded
        for i in fixed.indices where fixed[i].hasImage {
            if !existingImageIDs.contains(fixed[i].id) { fixed[i].hasImage = false }
        }
        items = fixed
        sort()
    }

    mutating func setHasImage(_ value: Bool, id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].hasImage = value
    }

    func item(id: String) -> ClipItem? { items.first { $0.id == id } }

    // MARK: - 持久化

    /// 历史里是用户复制的任意文本，JSONSerialization 对特殊字符串会抛 ObjC 异常
    /// （`try?` 挡不住）→ 必须走 SafeJSON。见 SafeJSON 注释。
    func encode() -> Data? { SafeJSON.data(items.map(\.dict)) }

    static func decode(data: Data) -> [ClipItem] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap(ClipItem.from)
    }
}
