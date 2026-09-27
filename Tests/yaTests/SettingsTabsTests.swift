import XCTest
import Cocoa
@testable import yaCore

/// 设置窗口的 tab 布局：分几个 tab、切换时换内容、高度跟着内容走、
/// 底部提示不被换掉、语言切换重建后仍停在原来那个 tab。
///
/// 这些是窗口行为，只能真建一个窗口来测（AppKit 控件需要先有 NSApplication）。
final class SettingsTabsTests: YaTestCase {
    private var wc: SettingsWindowController!
    /// 语言设置是共享的，测完必须还原，别把用户真机的配置改掉
    private var savedLanguage: String?

    override func setUp() {
        super.setUp()
        savedLanguage = UserDefaults.standard.object(forKey: "ya.lang") as? String
        _ = NSApplication.shared
        wc = SettingsWindowController()
    }

    override func tearDown() {
        wc?.window?.orderOut(nil)
        wc?.close()
        wc = nil
        if let v = savedLanguage {
            UserDefaults.standard.set(v, forKey: "ya.lang")
        } else {
            UserDefaults.standard.removeObject(forKey: "ya.lang")
        }
        super.tearDown()
    }

    private func select(tab index: Int) {
        wc.tabControl.selectedSegment = index
        NSApp.sendAction(wc.tabControl.action!, to: wc.tabControl.target, from: wc.tabControl)
    }

    func testFourTabsBuilt() {
        // 通用 / 快捷键 / 插件与数据 / 高级
        XCTAssertEqual(wc.tabControl.segmentCount, 4)
        // tab 内容一次建好，切换只是挂载/卸载
        XCTAssertEqual(wc.tabContainer.subviews.count, 1)
    }

    func testSwitchingTabReplacesContent() {
        let first = wc.tabContainer.subviews.first
        select(tab: 2)
        let second = wc.tabContainer.subviews.first
        XCTAssertEqual(wc.tabContainer.subviews.count, 1)
        XCTAssertNotNil(second)
        XCTAssertFalse(second === first, "切 tab 后应换成另一块内容")
        XCTAssertEqual(wc.tabControl.selectedSegment, 2)
    }

    func testWindowHeightFollowsContent() {
        let general = wc.window!.frame.height
        XCTAssertGreaterThanOrEqual(general, 240)
        XCTAssertLessThanOrEqual(general, 620)

        select(tab: 3) // 高级：只有两行按钮 + 一句提示，内容最短
        let advanced = wc.window!.frame.height
        XCTAssertLessThan(advanced, general, "内容少了窗口应该跟着变矮")
        XCTAssertGreaterThanOrEqual(advanced, 240)

        select(tab: 0)
        XCTAssertEqual(wc.window!.frame.height, general, accuracy: 1, "切回去应恢复到原来的高度")
    }

    func testStatusLabelSurvivesTabSwitch() {
        let label = wc.statusLabel
        XCTAssertNotNil(label)
        select(tab: 2)
        XCTAssertTrue(wc.statusLabel === label, "底部提示不该随 tab 一起被换掉")
    }

    func testLanguageChangeRebuildsAndKeepsTab() {
        select(tab: 1) // 快捷键
        let beforeZh = AppSettings.isZh
        AppSettings.shared.language = beforeZh ? .en : .zh
        NotificationCenter.default.post(name: .yaSettingsChanged, object: nil)

        XCTAssertNotEqual(AppSettings.isZh, beforeZh, "语言应该真的换了")
        XCTAssertEqual(wc.tabControl.segmentCount, 4, "重建后 tab 还在")
        XCTAssertEqual(wc.tabControl.selectedSegment, 1, "重建后应停在原来那个 tab")
        XCTAssertEqual(wc.tabContainer.subviews.count, 1)
    }
}
