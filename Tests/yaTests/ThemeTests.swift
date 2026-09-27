import XCTest
@testable import yaCore

/// 深浅色主题：三种模式只映射到一个 AppKit appearance —— auto = 不设置（跟随系统）。
///
/// 这里只验映射与设置回显：真正 `NSApp.appearance = …` 需要跑着的 NSApplication，
/// 放到单测里会因为找不到 app 而没有意义（那条路径靠手动改设置看效果）。
///
/// 注意：AppSettings 写的是 UserDefaults.standard，用完必须还原，别改掉用户真机的配置。
final class ThemeTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: "ya.theme")
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: "ya.theme") }
        else { UserDefaults.standard.removeObject(forKey: "ya.theme") }
        super.tearDown()
    }

    func testAppearanceNames() {
        XCTAssertNil(AppTheme.auto.appearanceName, "auto = 不设置 appearance，交给系统")
        XCTAssertEqual(AppTheme.light.appearanceName, "NSAppearanceNameAqua")
        XCTAssertEqual(AppTheme.dark.appearanceName, "NSAppearanceNameDarkAqua")
    }

    func testCaseIterableCoversAllModes() {
        XCTAssertEqual(AppTheme.allCases.map(\.rawValue), ["auto", "light", "dark"])
    }

    func testSettingsRoundTripAndPopupIndex() {
        let s = AppSettings.shared
        s.theme = .dark
        XCTAssertEqual(s.theme, .dark)
        XCTAssertEqual(Theme.popupIndex, 2)

        s.theme = .light
        XCTAssertEqual(Theme.popupIndex, 1)

        s.theme = .auto
        XCTAssertEqual(s.theme, .auto)
        XCTAssertEqual(Theme.popupIndex, 0)
    }

    /// 手改 defaults 写出未知值时退回 auto，不能让界面卡在某个半截状态
    func testUnknownValueFallsBackToAuto() {
        UserDefaults.standard.set("sepia", forKey: "ya.theme")
        XCTAssertEqual(AppSettings.shared.theme, .auto)
    }
}
