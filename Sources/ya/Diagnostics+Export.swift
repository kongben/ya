import Cocoa
import UniformTypeIdentifiers

/// 诊断导出的 UI 部分（保存面板 + 收尾提示）。
/// 与 `Diagnostics` 分开：`Diagnostics` 只依赖 Foundation，可以在单测里直接调；
/// 这个扩展碰 AppKit，只给菜单栏和设置窗口这类 UI 调用方用。
extension Diagnostics {
    /// 弹保存面板 → 写出诊断文件 → 在 Finder 里选中。返回是否导出成功
    @discardableResult
    static func exportViaPanel() -> Bool {
        let save = NSSavePanel()
        save.nameFieldStringValue = defaultFileName()
        save.allowedContentTypes = [UTType.plainText]
        save.canCreateDirectories = true
        save.isExtensionHidden = false

        // 与 Alert 同一个坑：accessory（无 Dock 图标）模式下直接 runModal() 可能一闪而过，
        // 展示期间临时切成 .regular，结束后恢复用户设置
        let previous = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = save.runModal()
        NSApp.setActivationPolicy(AppSettings.shared.showDockIcon ? .regular : previous)

        guard response == .OK, let url = save.url else { return false }
        do {
            try export(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        } catch {
            let zh = AppSettings.isZh
            Alert.show(title: zh ? "导出失败" : "Export failed",
                       info: error.localizedDescription,
                       style: .warning)
            return false
        }
    }
}
