import Cocoa

/// 设置窗口：按主题分成几个 tab（通用 / 快捷键 / 插件与数据 / 高级），
/// 底部固定状态提示 + 版本信息，切 tab 时窗口高度跟着内容走。
///
/// 以前所有选项堆在一列里，窗口越加越长、也分不清哪块管什么；
/// 现在每个 tab 的内容在 buildUI 时一次性建好并保留引用，切换只是挂载/卸载，
/// 控件引用（弹窗、勾选框、快捷键录制器）全程稳定。
final class SettingsWindowController: NSWindowController {
    private var langPopup: NSPopUpButton!
    private var themePopup: NSPopUpButton!
    private var launchButton: NSButton!
    private var dockButton: NSButton!
    /// 底部状态提示：切 tab 不重建它，所以 private(set) 方便单测断言"提示不会丢"
    private(set) var statusLabel: NSTextField!
    private var hotKeyRecorder: HotKeyRecorder!
    private var clipboardLimitPopup: NSPopUpButton!
    private var pluginManagerWC: PluginManagerWindowController?

    private(set) var tabControl: NSSegmentedControl!
    private(set) var tabContainer: NSView!
    private var tabViews: [NSView] = []
    private var selectedTab: Tab = .general

    private var zh: Bool { AppSettings.isZh }
    /// 建 UI 时的语言：语言变了就得整窗重建（.yaSettingsChanged 只有面板在听，
    /// 设置窗口自己不重建的话，从 English 切到中文后整页还是英文）
    private var builtZh: Bool = false

    /// 标签固定宽度：让所有行的控件左边缘对齐，短到中文三个字、英文 "Language" 都放得下
    private static let labelWidth: CGFloat = 92

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .yaSettingsChanged,
            object: nil
        )
    }

    /// 只有语言真的换了才重建：插件安装、清空历史等也会发这个通知，
    /// 那些情况下重建会把用户刚看到的提示和焦点弄丢
    @objc private func settingsDidChange() {
        guard zh != builtZh else { return }
        rebuildUI()
    }

    private func rebuildUI() {
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        buildUI()
    }

    private func buildUI() {
        guard let window = window, let content = window.contentView else { return }
        let zh = self.zh
        builtZh = zh
        window.title = zh ? "ya 设置" : "ya Settings"

        // tab 切换器：居中、各段按文字宽度，不给固定宽度（像系统设置那样）
        tabControl = NSSegmentedControl(
            labels: Tab.allCases.map { $0.title(zh) },
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged)
        )
        tabControl.selectedSegment = selectedTab.rawValue
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabControl)

        tabContainer = NSView()
        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabContainer)

        let footer = buildFooter(zh)
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            tabControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            tabControl.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            tabControl.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            tabContainer.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 16),
            tabContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tabContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            tabContainer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        tabViews = Tab.allCases.map { buildTab($0, zh: zh) }
        showTab(selectedTab, animated: false)
    }

    // MARK: - 各 tab

    private func buildTab(_ tab: Tab, zh: Bool) -> NSView {
        switch tab {
        case .general: return buildGeneral(zh: zh)
        case .shortcut: return buildShortcut(zh: zh)
        case .data: return buildData(zh: zh)
        case .advanced: return buildAdvanced(zh: zh)
        }
    }

    private func buildGeneral(zh: Bool) -> NSView {
        let stack = stackView()

        // 语言
        langPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        langPopup.addItems(withTitles: zh
            ? ["跟随系统", "简体中文", "English"]
            : ["Follow System", "Simplified Chinese", "English"])
        switch AppSettings.shared.language {
        case .auto: langPopup.selectItem(at: 0)
        case .zh: langPopup.selectItem(at: 1)
        case .en: langPopup.selectItem(at: 2)
        }
        langPopup.target = self
        langPopup.action = #selector(languageChanged)
        stack.addArrangedSubview(row(label: zh ? "语言" : "Language", control: langPopup))

        // 外观（深/浅色）：默认跟随系统，手动指定时由 Theme 改 NSApp.appearance
        themePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        themePopup.addItems(withTitles: zh
            ? ["跟随系统", "浅色", "深色"]
            : ["Follow System", "Light", "Dark"])
        themePopup.selectItem(at: Theme.popupIndex)
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        stack.addArrangedSubview(row(label: zh ? "外观" : "Appearance", control: themePopup))

        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        // 开机启动
        launchButton = NSButton(checkboxWithTitle: zh ? "登录时自动启动" : "Launch at login",
                                target: self, action: #selector(launchAtLoginChanged))
        launchButton.state = AppSettings.shared.launchAtLogin ? .on : .off
        stack.addArrangedSubview(indented(launchButton))

        // Dock 图标
        dockButton = NSButton(checkboxWithTitle: zh ? "显示 Dock 图标" : "Show Dock icon",
                              target: self, action: #selector(dockIconChanged))
        dockButton.state = AppSettings.shared.showDockIcon ? .on : .off
        stack.addArrangedSubview(indented(dockButton))

        return stack
    }

    private func buildShortcut(zh: Bool) -> NSView {
        let stack = stackView()

        hotKeyRecorder = HotKeyRecorder(hotKey: AppSettings.shared.hotKey)
        hotKeyRecorder.widthAnchor.constraint(equalToConstant: 180).isActive = true
        hotKeyRecorder.onChange = { [weak self] key in
            self?.applyHotKey(key)
        }
        hotKeyRecorder.onHint = { [weak self] text in self?.note(text) }
        let hotKeyRow = row(label: zh ? "快捷键" : "Shortcut", control: hotKeyRecorder)
        stack.addArrangedSubview(hotKeyRow)

        let hint = NSTextField(labelWithString: zh
            ? "呼出面板的全局快捷键。点击上方输入框后按下新的组合键"
            : "Global shortcut to summon the panel. Click the field above, then press your shortcut")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 330
        stack.addArrangedSubview(indented(hint))
        stack.setCustomSpacing(4, after: hotKeyRow)

        let reset = NSButton(title: zh ? "恢复默认 ⌥Space" : "Reset to ⌥Space",
                             target: self, action: #selector(resetHotKeyToDefault))
        stack.addArrangedSubview(indented(reset))

        return stack
    }

    private func buildData(zh: Bool) -> NSView {
        let stack = stackView()

        clipboardLimitPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        clipboardLimitPopup.addItems(withTitles: ["50", "100", "200", "500"])
        if let idx = ["50", "100", "200", "500"].firstIndex(of: "\(AppSettings.shared.clipboardLimit)") {
            clipboardLimitPopup.selectItem(at: idx)
        }
        clipboardLimitPopup.target = self
        clipboardLimitPopup.action = #selector(clipboardLimitChanged)
        stack.addArrangedSubview(row(label: zh ? "剪贴板" : "Clipboard", control: clipboardLimitPopup))

        let clipHint = NSTextField(labelWithString: zh
            ? "保留最近多少条剪贴板记录（插件 clipboard 用）"
            : "How many clipboard records to keep (used by the clipboard plugin)")
        clipHint.font = NSFont.systemFont(ofSize: 11)
        clipHint.textColor = .tertiaryLabelColor
        clipHint.preferredMaxLayoutWidth = 330
        stack.addArrangedSubview(indented(clipHint))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews[0])

        stack.setCustomSpacing(18, after: stack.arrangedSubviews[1])

        stack.addArrangedSubview(indented(buttonRow(zh ? [
            ("插件管理…", #selector(openPluginManager)),
            ("清空使用历史", #selector(clearHistory)),
        ] : [
            ("Plugin Manager…", #selector(openPluginManager)),
            ("Clear Usage History", #selector(clearHistory)),
        ])))

        return stack
    }

    private func buildAdvanced(zh: Bool) -> NSView {
        let stack = stackView()

        stack.addArrangedSubview(indented(buttonRow(zh ? [
            ("导出诊断信息…", #selector(exportDiagnostics)),
            ("重新加载界面", #selector(reloadInterface)),
        ] : [
            ("Export Diagnostics…", #selector(exportDiagnostics)),
            ("Reload Interface", #selector(reloadInterface)),
        ])))

        stack.addArrangedSubview(indented(buttonRow(zh ? [
            ("重置面板位置", #selector(resetPanelPosition)),
        ] : [
            ("Reset Panel Position", #selector(resetPanelPosition)),
        ])))

        let advHint = NSTextField(labelWithString: zh
            ? "面板拖到屏幕外或位置不对时，用“重置面板位置”回到默认位置"
            : "If the panel is off-screen, use “Reset Panel Position” to bring it back")
        advHint.font = NSFont.systemFont(ofSize: 11)
        advHint.textColor = .tertiaryLabelColor
        advHint.maximumNumberOfLines = 2
        advHint.preferredMaxLayoutWidth = 330
        stack.addArrangedSubview(indented(advHint))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[1])

        return stack
    }

    /// 底部固定区：状态提示 + 上次退出 / 版本。切 tab 不重建，提示不会丢
    private func buildFooter(_ zh: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.preferredMaxLayoutWidth = 380
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        // 上次是不是崩过：内测里最常听到的是"昨天还好好的"，这一行能立刻区分
        // 是崩溃还是设置被改了
        let abnormal = Diagnostics.previousLaunchWasAbnormal()
        let lastExit = NSTextField(labelWithString:
            (zh ? "上次退出：" : "Last exit: ") + (abnormal
                ? (zh ? "异常" : "abnormal")
                : (zh ? "正常" : "normal")))
        lastExit.font = NSFont.systemFont(ofSize: 11)
        lastExit.textColor = abnormal ? .systemOrange : .tertiaryLabelColor
        lastExit.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lastExit)

        let version = NSTextField(labelWithString:
            "ya \(NativeServices.appVersion) · \(AppSettings.shared.hotKey.displayString)")
        version.font = NSFont.systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(version)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            lastExit.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            lastExit.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lastExit.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            version.centerYAnchor.constraint(equalTo: lastExit.centerYAnchor),
            version.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            version.leadingAnchor.constraint(greaterThanOrEqualTo: lastExit.trailingAnchor, constant: 8),
        ])
        return container
    }

    // MARK: - 布局小工具

    private func stackView() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func row(label: String, control: NSView) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 10
        container.alignment = .centerY
        if !label.isEmpty {
            let l = NSTextField(labelWithString: label)
            l.font = NSFont.systemFont(ofSize: 13)
            l.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
            container.addArrangedSubview(l)
        }
        container.addArrangedSubview(control)
        return container
    }

    /// 没有标签的行（勾选框、提示文字）：左边留一个标签位，跟上面的控件对齐
    private func indented(_ control: NSView) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: Self.labelWidth + 10).isActive = true
        container.addArrangedSubview(spacer)
        container.addArrangedSubview(control)
        return container
    }

    private func buttonRow(_ items: [(String, Selector)]) -> NSView {
        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.spacing = 10
        for (title, sel) in items {
            rowStack.addArrangedSubview(NSButton(title: title, target: self, action: sel))
        }
        return rowStack
    }

    // MARK: - tab 切换

    @objc private func tabChanged() {
        guard let tab = Tab(rawValue: tabControl.selectedSegment) else { return }
        // 录制快捷键时切走 tab 会留下一个正在监听的控件，先让它收工
        hotKeyRecorder.setHotKey(AppSettings.shared.hotKey)
        showTab(tab, animated: true)
    }

    private func showTab(_ tab: Tab, animated: Bool) {
        guard let window = window, tabViews.indices.contains(tab.rawValue) else { return }
        selectedTab = tab
        tabContainer.subviews.forEach { $0.removeFromSuperview() }
        let v = tabViews[tab.rawValue]
        v.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
        ])
        fitToContent(animated: animated && window.isVisible)
    }

    /// 高度跟着当前 tab 的内容走：量出内容自然高度，换上新的窗口高度（顶部不动）
    private func fitToContent(animated: Bool) {
        guard let window = window, let v = tabContainer.subviews.first else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        // 窗口高度里除 tabContainer 之外的部分（标题栏 + tab 条 + 底部区 + 间距）
        let chrome = window.frame.height - tabContainer.frame.height
        let wanted = min(max(v.fittingSize.height + chrome, 240), 620)
        if abs(window.frame.height - wanted) < 1 { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - wanted
        frame.size.height = wanted
        window.setFrame(frame, display: true, animate: animated)
    }

    private func note(_ text: String) {
        statusLabel.stringValue = text
    }

    // MARK: - Actions

    @objc private func languageChanged() {
        let picked: AppLanguage
        switch langPopup.indexOfSelectedItem {
        case 1: picked = .zh
        case 2: picked = .en
        default: picked = .auto
        }
        AppSettings.shared.language = picked
        // 先发通知（本窗口会同步重建，statusLabel 换成新的），再写提示 ——
        // 否则提示写在马上就要被扔掉的旧标签上，用户什么也看不到
        NotificationCenter.default.post(name: .yaSettingsChanged, object: nil)
        note(zh ? "语言已切换，界面已重新加载" : "Language changed, interface reloaded")
    }

    @objc private func themeChanged() {
        Theme.selectPopupIndex(themePopup.indexOfSelectedItem)
        note(zh ? "外观已切换" : "Appearance changed")
    }

    private func applyHotKey(_ key: HotKey) {
        AppSettings.shared.hotKey = key
        // 由 AppDelegate 负责真正重新注册；注册失败（被系统占用）会在那里提示
        NotificationCenter.default.post(name: .yaHotKeyChanged, object: nil)
        note(zh ? "快捷键已设为 \(key.displayString)" : "Shortcut set to \(key.displayString)")
    }

    @objc private func resetHotKeyToDefault() {
        hotKeyRecorder.setHotKey(.default)
        applyHotKey(.default)
    }

    /// 剪贴板历史上限：下一次记录剪贴板时按新上限裁剪（由 ClipboardManager.trim 读设置）
    @objc private func clipboardLimitChanged() {
        let values = [50, 100, 200, 500]
        let idx = clipboardLimitPopup.indexOfSelectedItem
        let picked = values.indices.contains(idx) ? values[idx] : 100
        AppSettings.shared.clipboardLimit = picked
        note(zh ? "剪贴板历史上限：\(picked) 条" : "Clipboard history limit: \(picked)")
    }

    @objc private func launchAtLoginChanged() {
        let enabled = launchButton.state == .on
        AppSettings.shared.launchAtLogin = enabled
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.ya.agent.plist")
        if enabled {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key>
              <string>com.ya.agent</string>
              <key>ProgramArguments</key>
              <array>
                <string>\(CommandLine.arguments.first ?? "")</string>
              </array>
              <key>RunAtLoad</key>
              <true/>
              <key>KeepAlive</key>
              <false/>
            </dict>
            </plist>
            """
            do {
                try plist.write(to: url, atomically: true, encoding: .utf8)
                note(zh ? "已写入 LaunchAgent，下次登录生效" : "LaunchAgent written, effective on next login")
            } catch {
                note((zh ? "写入失败：" : "Failed to write: ") + error.localizedDescription)
            }
        } else {
            try? FileManager.default.removeItem(at: url)
            note(zh ? "已取消开机启动" : "Launch at login disabled")
        }
    }

    @objc private func dockIconChanged() {
        let show = dockButton.state == .on
        AppSettings.shared.showDockIcon = show
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    @objc private func openPluginManager() {
        NotificationCenter.default.post(name: .yaHidePanel, object: nil)
        if pluginManagerWC == nil { pluginManagerWC = PluginManagerWindowController() }
        pluginManagerWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reloadInterface() {
        NotificationCenter.default.post(name: .yaSettingsChanged, object: nil)
        note(zh ? "界面已重新加载" : "Interface reloaded")
    }

    /// 与菜单栏同一个动作：把版本 / 插件 / 冲突 / 最近日志打包成一个文本文件
    @objc private func exportDiagnostics() {
        note(Diagnostics.exportViaPanel()
             ? (zh ? "诊断信息已导出" : "Diagnostics exported")
             : (zh ? "已取消导出" : "Export cancelled"))
    }

    /// 面板拖到别处后回不来（或想回到屏幕中上方）时的复位入口
    @objc private func resetPanelPosition() {
        NotificationCenter.default.post(name: .yaResetPanelPosition, object: nil)
        note(zh ? "面板位置已重置" : "Panel position reset")
    }

    @objc private func clearHistory() {
        AppSettings.shared.clearUsageHistory()
        NotificationCenter.default.post(name: .yaSettingsChanged, object: nil)
        note(zh ? "使用历史已清空" : "Usage history cleared")
    }

    // MARK: - Tab

    private enum Tab: Int, CaseIterable {
        case general, shortcut, data, advanced

        func title(_ zh: Bool) -> String {
            switch self {
            case .general: return zh ? "通用" : "General"
            case .shortcut: return zh ? "快捷键" : "Shortcut"
            case .data: return zh ? "插件与数据" : "Plugins & Data"
            case .advanced: return zh ? "高级" : "Advanced"
            }
        }
    }
}

extension Notification.Name {
    static let yaSettingsChanged = Notification.Name("yaSettingsChanged")
    static let yaResetPanelPosition = Notification.Name("yaResetPanelPosition")
}
