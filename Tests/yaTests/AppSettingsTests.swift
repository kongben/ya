import Carbon.HIToolbox
import XCTest
@testable import yaCore

/// 快捷键展示 / 系统保留组合黑名单 / 设置的取值边界
///
/// 注意：AppSettings 只有一个 shared 实例且写 UserDefaults.standard，
/// 凡是会改设置的用例都要在 tearDown 里恢复原值，别把用户真机的配置改掉。
final class AppSettingsTests: XCTestCase {
    private var snapshot: [String: Any?] = [:]
    private let keys = ["ya.lang", "ya.clipboard.limit", "ya.panel.x", "ya.panel.y",
                        "ya.hotkey.keyCode", "ya.hotkey.modifiers"]

    override func setUp() {
        super.setUp()
        for k in keys { snapshot[k] = UserDefaults.standard.object(forKey: k) }
    }

    override func tearDown() {
        for (k, v) in snapshot {
            if let v { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    // MARK: - 快捷键

    func testDefaultHotKeyDisplay() {
        XCTAssertEqual(HotKey.default.displayString, "⌥ Space")
        XCTAssertTrue(HotKey.default.hasModifier)
    }

    func testDisplayStringOrderIsControlOptionShiftCommand() {
        var k = HotKey()
        k.modifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        k.keyCode = UInt32(kVK_ANSI_A)
        XCTAssertEqual(k.displayString, "⌃⌥⇧⌘ A")
    }

    /// 没有修饰键的全局热键会把正常输入吞掉，不允许
    func testHasModifier() {
        var k = HotKey()
        k.modifiers = 0
        XCTAssertFalse(k.hasModifier)
        k.modifiers = UInt32(shiftKey)
        XCTAssertTrue(k.hasModifier)
    }

    /// 这些组合就算注册成功，按下时也会被系统截获（⌘Space 是聚焦搜索…）
    func testSystemReserved() {
        func hot(_ mods: UInt32, _ code: Int) -> HotKey {
            HotKey(keyCode: UInt32(code), modifiers: mods)
        }
        XCTAssertTrue(hot(UInt32(cmdKey), kVK_Space).maybeSystemReserved)
        XCTAssertTrue(hot(UInt32(cmdKey | optionKey), kVK_Space).maybeSystemReserved)
        XCTAssertTrue(hot(UInt32(controlKey), kVK_Space).maybeSystemReserved)
        XCTAssertTrue(hot(UInt32(cmdKey), kVK_Tab).maybeSystemReserved)
        XCTAssertTrue(hot(UInt32(cmdKey), kVK_ANSI_Comma).maybeSystemReserved)
        XCTAssertFalse(hot(UInt32(optionKey), kVK_Space).maybeSystemReserved)
        XCTAssertFalse(hot(UInt32(cmdKey | shiftKey), kVK_ANSI_A).maybeSystemReserved)
    }

    func testKeyNames() {
        XCTAssertEqual(KeyNameMap.name(keyCode: UInt32(kVK_Space)), "Space")
        XCTAssertEqual(KeyNameMap.name(keyCode: UInt32(kVK_Return)), "↩")
        XCTAssertEqual(KeyNameMap.name(keyCode: UInt32(kVK_ANSI_A)), "A")
        XCTAssertEqual(KeyNameMap.name(keyCode: UInt32(kVK_ANSI_Minus)), "-")
        XCTAssertEqual(KeyNameMap.name(keyCode: 999), "Key999")
    }

    /// 半截状态（只写了 keyCode 没写 modifiers）要退回默认，别注册出一个裸按键
    func testHotKeyFallsBackWhenIncomplete() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "ya.hotkey.keyCode")
        d.removeObject(forKey: "ya.hotkey.modifiers")
        XCTAssertEqual(AppSettings.shared.hotKey, .default)

        d.set(Int(kVK_ANSI_A), forKey: "ya.hotkey.keyCode")
        d.removeObject(forKey: "ya.hotkey.modifiers")
        XCTAssertEqual(AppSettings.shared.hotKey, .default)

        d.set(Int(kVK_ANSI_A), forKey: "ya.hotkey.keyCode")
        d.set(Int(optionKey), forKey: "ya.hotkey.modifiers")
        XCTAssertEqual(AppSettings.shared.hotKey.keyCode, UInt32(kVK_ANSI_A))
    }

    // MARK: - 设置边界

    func testClipboardLimitIsClamped() {
        let s = AppSettings.shared
        s.clipboardLimit = 50
        XCTAssertEqual(s.clipboardLimit, 50)
        s.clipboardLimit = 5      // 太小
        XCTAssertEqual(s.clipboardLimit, 100, "越界值回退到默认 100")
        s.clipboardLimit = 9999   // 太大
        XCTAssertEqual(s.clipboardLimit, 100)
        s.clipboardLimit = 500
        XCTAssertEqual(s.clipboardLimit, 500, "边界值要能生效")
    }

    func testPanelOriginRoundTrip() {
        let s = AppSettings.shared
        s.panelOrigin = nil
        XCTAssertNil(s.panelOrigin)
        s.panelOrigin = (12.5, 34.5)
        XCTAssertEqual(s.panelOrigin?.x, 12.5)
        XCTAssertEqual(s.panelOrigin?.y, 34.5)
        s.panelOrigin = nil
        XCTAssertNil(s.panelOrigin)
    }

    func testResolvedLanguage() {
        let s = AppSettings.shared
        s.language = .en
        XCTAssertEqual(s.resolvedLanguage(), "en")
        s.language = .zh
        XCTAssertEqual(s.resolvedLanguage(), "zh")
        XCTAssertTrue(AppSettings.isZh)
        s.language = .auto
        XCTAssertEqual(s.resolvedLanguage(), Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en")
    }
}
