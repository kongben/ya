import Cocoa

/// 统一弹窗入口。之前每个文件各写一遍 `NSAlert()` + 按钮 + `runModal()`，
/// 而且**少写了 activationPolicy 切换**的那几处都会在 accessory（无 Dock 图标）模式下
/// 出现"弹窗一闪就没"的问题——这里把两个坑一次性收口。
enum Alert {
    /// 单按钮提示（默认按钮文案「好」/OK）
    @discardableResult
    static func show(title: String,
                     info: String = "",
                     style: NSAlert.Style = .informational,
                     button: String? = nil,
                     icon: NSImage? = nil) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        if !info.isEmpty { alert.informativeText = info }
        if let icon = icon { alert.icon = icon }
        alert.addButton(withTitle: button ?? (AppSettings.isZh ? "好" : "OK"))
        return runModal(alert)
    }

    /// 确认框：点确认按钮返回 true（确认按钮在前，取消在后；Esc 走取消）
    static func confirm(title: String,
                        info: String,
                        confirm: String,
                        cancel: String? = nil,
                        style: NSAlert.Style = .warning) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel ?? (AppSettings.isZh ? "取消" : "Cancel"))
        return runModal(alert) == .alertFirstButtonReturn
    }

    /// accessory 应用没有窗口时 `runModal()` 可能立刻返回（表现为弹窗被自动按掉），
    /// 展示期间临时切成 .regular，结束后恢复用户设置
    @discardableResult
    private static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let previous = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        NSApp.setActivationPolicy(AppSettings.shared.showDockIcon ? .regular : previous)
        return response
    }
}
