import Cocoa

/// 菜单栏（状态栏）图标：自动生成 "ya" 字样，点击弹出菜单
final class StatusBarController: NSObject, NSMenuDelegate {
    /// 作者：菜单栏「关于 ya」里显示
    static let author = "zhouyefei"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: PanelController
    private var settingsWC: SettingsWindowController?
    private var pluginManagerWC: PluginManagerWindowController?
    // 持有引用而不是用 menu.item(at:) 索引定位——插入/调整菜单项时索引会错位
    private var toggleItem: NSMenuItem!
    private var settingsItem: NSMenuItem!
    private var pluginsItem: NSMenuItem!
    private var aboutItem: NSMenuItem!
    private var diagnosticsItem: NSMenuItem!
    private var dataFolderItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    init(panel: PanelController) {
        self.panel = panel
        super.init()
        if let button = statusItem.button {
            // 只留小黄鸭，不带 "ya" 字样：菜单栏位置金贵，快捷键提示放 tooltip 里
            let image = DuckIcon.menuBarImage(height: 20, showText: false)
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "ya · \(AppSettings.shared.hotKey.displayString)"
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotKeyRegistered),
            name: .yaHotKeyRegistered,
            object: nil
        )
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        toggleItem = NSMenuItem(title: "", action: #selector(togglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        settingsItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        pluginsItem = NSMenuItem(title: "", action: #selector(openPluginManager), keyEquivalent: "")
        pluginsItem.target = self
        menu.addItem(pluginsItem)
        menu.addItem(NSMenuItem.separator())
        diagnosticsItem = NSMenuItem(title: "", action: #selector(exportDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)
        dataFolderItem = NSMenuItem(title: "", action: #selector(openDataFolder), keyEquivalent: "")
        dataFolderItem.target = self
        menu.addItem(dataFolderItem)
        aboutItem = NSMenuItem(title: "", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        let zh = AppSettings.isZh
        toggleItem.title = panel.isPanelVisible
            ? (zh ? "隐藏面板" : "Hide Panel")
            : (zh ? "显示面板" : "Show Panel")
        settingsItem.title = zh ? "设置…" : "Settings…"
        pluginsItem.title = zh ? "插件管理…" : "Plugin Manager…"
        aboutItem.title = zh ? "关于 ya" : "About ya"
        diagnosticsItem.title = zh ? "导出诊断信息…" : "Export Diagnostics…"
        dataFolderItem.title = zh ? "打开数据目录" : "Open Data Folder"
        quitItem.title = zh ? "退出 ya" : "Quit ya"
    }

    @objc private func togglePanel() {
        panel.toggle()
    }

    @objc private func hotKeyRegistered() {
        statusItem.button?.toolTip = "ya · \(AppSettings.shared.hotKey.displayString)"
    }

    /// 打开任何常规窗口前先收起面板：面板是 floating 级，会盖在窗口上面
    private func hidePanel() {
        NotificationCenter.default.post(name: .yaHidePanel, object: nil)
    }

    @objc private func openSettings() {
        hidePanel()
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPluginManager() {
        hidePanel()
        if pluginManagerWC == nil { pluginManagerWC = PluginManagerWindowController() }
        pluginManagerWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        hidePanel()
        let zh = AppSettings.isZh
        let hk = AppSettings.shared.hotKey.displayString
        Alert.show(title: "ya",
                   info: zh
                    ? "版本 \(NativeServices.appVersion)\n作者 \(Self.author)\n快捷键 \(hk) 呼出面板"
                    : "Version \(NativeServices.appVersion)\nAuthor \(Self.author)\nPress \(hk) to open the panel",
                   icon: DuckIcon.appIcon(size: 64))
    }

    /// 导出诊断信息：版本 / 系统 / 插件 / 冲突 / 数据规模 / 最近日志。
    /// 内测期间用户报障时只要这一个文件就够定位大半问题
    @objc private func exportDiagnostics() {
        hidePanel()
        Diagnostics.exportViaPanel()
    }

    @objc private func openDataFolder() {
        hidePanel()
        NSWorkspace.shared.open(AppPaths.root)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
