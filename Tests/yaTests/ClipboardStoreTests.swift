import XCTest
@testable import yaCore

/// 剪贴板历史的纯数据规则：去重、收藏保护、上限裁剪。
/// 这些规则以前埋在 ClipboardManager 里（要造真剪贴板才能测），现在独立成单测。
final class ClipboardStoreTests: XCTestCase {
    private var store = ClipboardStore()
    private var clock: TimeInterval = 1_000

    private func text(_ s: String, pinned: Bool = false) -> ClipItem {
        clock += 1
        return ClipItem(id: UUID().uuidString, kind: .text, text: s, paths: [],
                        timestamp: clock, pinned: pinned, hasImage: false)
    }

    private func image() -> ClipItem {
        clock += 1
        return ClipItem(id: UUID().uuidString, kind: .image, text: "", paths: [],
                        timestamp: clock, pinned: false, hasImage: true)
    }

    func testInsertGoesToFront() {
        _ = store.insert(text("a"), limit: 10)
        _ = store.insert(text("b"), limit: 10)
        XCTAssertEqual(store.items.map(\.text), ["b", "a"])
    }

    /// 同一段文字反复复制，不该占满历史
    func testInsertDedupesSameText() {
        _ = store.insert(text("a"), limit: 10)
        _ = store.insert(text("b"), limit: 10)
        let r = store.insert(text("a"), limit: 10)
        XCTAssertTrue(r.inserted)
        XCTAssertEqual(store.items.map(\.text), ["a", "b"])
        XCTAssertEqual(store.items.count, 2)
    }

    /// 重复复制同一段：替换掉旧条目并提到最前（时间戳也跟着刷新），不会越堆越多
    func testInsertReplacesDuplicate() {
        let first = text("a")
        _ = store.insert(first, limit: 10)
        _ = store.insert(text("b"), limit: 10)
        let r = store.insert(text("a"), limit: 10)
        XCTAssertTrue(r.inserted)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.text, "a")
        XCTAssertNotEqual(store.items.first?.id, first.id, "旧条目已被新的顶替")
    }

    /// 收藏项已经是首条时不再插入副本（否则收藏会被一条未收藏的同内容条目顶掉）
    func testInsertSkipsPinnedDuplicateAtFront() {
        let pinned = text("a", pinned: true)
        _ = store.insert(pinned, limit: 10)
        let r = store.insert(text("a"), limit: 10)
        XCTAssertFalse(r.inserted)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.id, pinned.id)
    }

    func testTrimDropsOldestUnpinned() {
        for s in ["1", "2", "3", "4", "5"] { _ = store.insert(text(s), limit: 3) }
        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.items.map(\.text), ["5", "4", "3"])
    }

    /// 收藏项不能被上限裁掉
    func testTrimKeepsPinned() {
        let pinned = text("keep", pinned: true)
        _ = store.insert(pinned, limit: 10)
        for s in ["1", "2", "3", "4"] { _ = store.insert(text(s), limit: 2) }
        XCTAssertTrue(store.items.contains { $0.id == pinned.id }, "收藏项必须活下来")
        XCTAssertEqual(store.items.count, 2)
    }

    /// 被裁掉的 id 要返回给调用方去删缩略图
    func testTrimReturnsEvictedIDs() {
        let first = text("1")
        _ = store.insert(first, limit: 10)
        let (_, evicted) = store.insert(text("2"), limit: 1)
        XCTAssertEqual(evicted, [first.id])
    }

    /// 图片不去重：连续截两张图必须都在（它们 text 都是空串）
    func testAppendImagesDoesNotDedupe() {
        let a = image()
        let b = image()
        _ = store.append(a, limit: 10)
        _ = store.append(b, limit: 10)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.map(\.id), [b.id, a.id])
    }

    func testTogglePinSortsPinnedFirst() {
        let a = text("a")
        _ = store.insert(a, limit: 10)
        _ = store.insert(text("b"), limit: 10)
        XCTAssertTrue(store.togglePin(id: a.id))
        XCTAssertEqual(store.items.first?.id, a.id)
        XCTAssertFalse(store.togglePin(id: "nope"), "不存在的 id 返回 false")
    }

    func testRemove() {
        let a = text("a")
        _ = store.insert(a, limit: 10)
        XCTAssertEqual(store.remove(id: a.id), a.id)
        XCTAssertNil(store.remove(id: a.id))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testClearKeepingPinned() {
        let pinned = text("keep", pinned: true)
        _ = store.insert(pinned, limit: 10)
        _ = store.insert(text("gone"), limit: 10)
        let removed = store.clear()
        XCTAssertEqual(store.items.map(\.id), [pinned.id])
        XCTAssertEqual(removed.count, 1)

        let all = store.clear(keepingPinned: false)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(all, [pinned.id])
    }

    func testReplaceAllCorrectsHasImage() {
        let withImage = image()
        let lost = image()
        store.replaceAll([withImage, lost], existingImageIDs: [withImage.id])
        XCTAssertTrue(store.items.first { $0.id == withImage.id }?.hasImage ?? false)
        XCTAssertFalse(store.items.first { $0.id == lost.id }?.hasImage ?? true,
                       "磁盘上没有缩略图的条目要把 hasImage 纠正为 false")
    }

    func testEncodeDecodeRoundTrip() {
        _ = store.insert(text("hello 🎉\n\"quoted\""), limit: 10)
        _ = store.append(image(), limit: 10)
        guard let data = store.encode() else { return XCTFail("encode 失败") }
        let decoded = ClipboardStore.decode(data: data)
        XCTAssertEqual(decoded.count, store.items.count)
        XCTAssertEqual(decoded.map(\.id), store.items.map(\.id))
        XCTAssertEqual(decoded.first?.kind, .image)
        XCTAssertEqual(decoded.last?.text, "hello 🎉\n\"quoted\"")
    }

    func testDecodeIgnoresGarbage() {
        XCTAssertEqual(ClipboardStore.decode(data: Data("not json".utf8)).count, 0)
        XCTAssertEqual(ClipboardStore.decode(data: Data("[{\"kind\":\"nope\"}]".utf8)).count, 0)
    }
}
