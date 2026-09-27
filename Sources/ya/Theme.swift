import AppKit

/// 深浅色主题。
///
/// 面板是 WKWebView 画的，颜色全靠 CSS 的 `prefers-color-scheme`（见 shell.css）：
/// - `auto` → `NSApp.appearance = nil`，WebView 跟随系统外观，系统一切换它自己就变；
/// - `light` / `dark` → 设置 `NSApp.appearance`，**同一个媒体查询**就会被强制判成对应模式，
///   所以样式表只有一份，不需要 `data-theme` 之类的第二套覆盖。
///
/// 顺带一个好处：设置 AppKit 层的 appearance 后，设置窗口 / 插件管理窗口也一起换肤。
enum Theme {
    /// 启动时与设置里改外观后都要调一次
    static func apply() {
        let name = AppSettings.shared.theme.appearanceName
        NSApp.appearance = name.flatMap { NSAppearance(named: NSAppearance.Name($0)) }
    }

    /// 设置里选了哪一项（0 跟随系统 / 1 浅色 / 2 深色），供 UI 回显
    static var popupIndex: Int {
        switch AppSettings.shared.theme {
        case .auto: return 0
        case .light: return 1
        case .dark: return 2
        }
    }

    static func selectPopupIndex(_ index: Int) {
        let picked = [AppTheme.auto, .light, .dark][min(max(index, 0), 2)]
        AppSettings.shared.theme = picked
        apply()
        NotificationCenter.default.post(name: .yaThemeChanged, object: nil)
    }
}

extension Notification.Name {
    /// 外观被手动改了。系统自己切换不用通知（WebView 会自动更新），
    /// 这里只为了「改设置时面板正好藏着」的情况补一次重载。
    static let yaThemeChanged = Notification.Name("yaThemeChanged")
}
