import Cocoa
import Carbon

/// 只为给 Edit 菜单提供标准编辑 action 的 selector。
/// 方法体是空的没关系：菜单 item 的 target 为 nil，真正干活的是 responder chain
/// 上的 WKWebView，这个类的作用只是让 `#selector(...)` 能编译出来。
private final class EditMenuActions: NSObject {
    @objc func undo(_ sender: Any?) {}
    @objc func redo(_ sender: Any?) {}
    @objc func cut(_ sender: Any?) {}
    @objc func copy(_ sender: Any?) {}
    @objc func paste(_ sender: Any?) {}
    @objc func selectAll(_ sender: Any?) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController!
    private var hotKeyManager: HotKeyManager!
    private var statusBar: StatusBarController!
    /// SIGTERM 监听源要保持引用，否则 resume 后就被释放、信号再也收不到
    private var termSource: DispatchSourceSignal?

    /// 注册 URL scheme 处理器（要在 willFinish 阶段，否则冷启动时收不到事件）
    /// 输入框的 ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z 靠的是 responder chain：
    /// AppKit 先拿 key equivalent 去 mainMenu 里找匹配的 item，再沿响应链派发 action。
    /// ya 是 accessory app（没有菜单栏），匹配不到任何 item，这些键按下去完全没反应。
    /// 补一个不显示的 Edit 菜单即可——item 的 target 留空，事件会自己送到 WKWebView。
    private func buildEditMenu() {
        let edit = NSMenu(title: "Edit")
        let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", #selector(EditMenuActions.undo(_:)), "z", .command),
            ("Redo", #selector(EditMenuActions.redo(_:)), "z", [.command, .shift]),
            ("Cut", #selector(EditMenuActions.cut(_:)), "x", .command),
            ("Copy", #selector(EditMenuActions.copy(_:)), "c", .command),
            ("Paste", #selector(EditMenuActions.paste(_:)), "v", .command),
            ("Select All", #selector(EditMenuActions.selectAll(_:)), "a", .command),
        ]
        for (title, action, key, mods) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            edit.addItem(item)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// `pkill` / `kill` 发的是 SIGTERM，它**不会**走到 `applicationWillTerminate`——
    /// 而 `./stop.sh` 用的正是 pkill。不处理的话每次脚本重启都会被判成"上次崩溃了"，
    /// 诊断报告里那条「上次退出：异常」就成了噪音。这里把 SIGTERM 也走一次正常退出流程。
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN) // 交给下面的 DispatchSource，别让系统按默认行为直接杀掉
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.terminateGracefully()
        }
        source.resume()
        termSource = source
    }

    private func terminateGracefully() {
        Diagnostics.markCleanExit()
        NSApp.terminate(nil)
    }

    /// 正常退出时把启动标记改成「干净退出」。被强杀（SIGKILL）或崩溃时不会走到这里，
    /// 下次启动 `Diagnostics.previousLaunchWasAbnormal()` 就能发现
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.markCleanExit()
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                      withReply reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: raw) else { return }
        DeepLinkHandler.handle(url: url)
    }

    @objc private func registerHotKeyFromNotice() {
        registerHotKey(announce: true)
    }

    /// 注册全局快捷键；失败（被系统/其它应用占用）时提示，并把设置回滚到默认
    private func registerHotKey(announce: Bool) {
        let tried = AppSettings.shared.hotKey.displayString
        if hotKeyManager.install() {
            NotificationCenter.default.post(name: .yaHotKeyRegistered, object: nil)
            // 注册成功 ≠ 按得出来：被系统截获的组合要提前说清楚，否则用户只会觉得"改了没反应"
            if announce, AppSettings.shared.hotKey.maybeSystemReserved {
                hotKeyNotice(reserved: true, tried: tried)
            }
            return
        }
        // 注册不上的组合（典型：⌘Space 属于聚焦搜索）留着也没意义，回退默认并再试一次
        AppSettings.shared.hotKey = .default
        hotKeyManager.install()
        NotificationCenter.default.post(name: .yaHotKeyRegistered, object: nil)
        guard announce else { return }
        hotKeyNotice(reserved: false, tried: tried)
    }

    /// 快捷键提示：`reserved` = 注册成功但可能被系统截获；否则 = 注册失败已回退默认
    private func hotKeyNotice(reserved: Bool, tried: String) {
        let zh = AppSettings.isZh
        let title = zh
            ? (reserved ? "该组合可能无效" : "快捷键无法使用")
            : (reserved ? "This combo may not work" : "Shortcut unavailable")
        let info: String
        if reserved {
            info = zh
                ? "\(tried) 通常已被 macOS 占用（聚焦搜索 / 输入法切换等），按下时系统可能优先响应。若无反应，请换一个组合。"
                : "\(tried) is usually taken by macOS (Spotlight, input switching…). If nothing happens, pick another combo."
        } else {
            info = zh
                ? "\(tried) 已被系统或其它应用占用，已恢复为 \(HotKey.default.displayString)。"
                : "\(tried) is already taken by macOS or another app. Reverted to \(HotKey.default.displayString)."
        }
        Alert.show(title: title, info: info, style: .warning)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildEditMenu()
        installTerminationHandler()
        panelController = PanelController()
        panelController.setup()
        hotKeyManager = HotKeyManager { [weak self] in
            self?.panelController.toggle()
        }
        registerHotKey(announce: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(registerHotKeyFromNotice),
            name: .yaHotKeyChanged, object: nil
        )

        // 菜单栏图标（默认不显示 Dock 图标，可在设置里打开）
        NSApp.setActivationPolicy(AppSettings.shared.showDockIcon ? .regular : .accessory)
        statusBar = StatusBarController(panel: panelController)

        debugHooks()
    }

    /// 调试用（设置环境变量生效，正常启动无副作用）：
    ///   YA_DEBUG=1        启动时打印插件列表
    ///   YA_IMPORT=<zip>   启动时导入指定插件压缩包
    private func debugHooks() {
        let env = ProcessInfo.processInfo.environment
        // GUI 进程 stdout 是块缓冲的，必须 fflush 才能看到输出
        func names() -> String {
            PluginLoader.list().map { "\($0["id"] ?? "?")(\($0["source"] ?? "?"))" }.joined(separator: ", ")
        }
        if env["YA_DEBUG"] == "1" {
            // 编辑快捷键（⌘C/⌘V/⌘A）依赖 mainMenu 存在，自检一下菜单建起来了
            let editCount = NSApp.mainMenu?.item(at: 0)?.submenu?.items.count ?? 0
            Log.info("edit menu items: \(editCount)")
            Log.info("hotkey: \(AppSettings.shared.hotKey.displayString) "
                + "(code=\(AppSettings.shared.hotKey.keyCode) mods=\(AppSettings.shared.hotKey.modifiers))")
            Log.info("plugins: \(names())")
            // 关键字索引（含别名、自定义覆盖、冲突）与图标自检
            for e in PluginIndex.shared.entries() {
                let icon = PluginIcon.make(id: e.id, entry: e)
                let b64 = IconUtil.pngBase64(icon)
                Log.info("  \(e.id): v\(e.version.display) keyword=\(e.primaryKeyword.isEmpty ? "-" : e.primaryKeyword) "
                    + "keywords=[\(e.keywords.joined(separator: ","))] "
                    + "declared=[\(e.declaredKeywords.joined(separator: ","))] "
                    + "conflict=\(e.conflictWith ?? "-") pinyin=\(e.pinyinFull)/\(e.pinyinInitials) "
                    + "icon=\(b64.count)b64")
                if !e.features.isEmpty {
                    let desc = e.features
                        .map { "\($0.cmd)[\($0.keywords.joined(separator: ","))]" }
                        .joined(separator: " ")
                    Log.info("    features: \(desc)")
                }
            }
            for c in PluginIndex.shared.conflicts() {
                Log.info("  conflict: \(c.id) 的关键字 \(c.keyword) 被 \(c.ownerId) 占用")
            }
            // 插件样式自检：style.css 是否存在、相对 url() 是否已内联成 data URL
            for e in PluginIndex.shared.entries() {
                let css = PluginLoader.load(id: e.id)["css"] as? String ?? ""
                guard !css.isEmpty else { continue }
                let inlined = css.contains("data:image") || css.contains("data:font")
                Log.info("  css: \(e.id) \(css.count) 字符, 内联资源=\(inlined ? "是" : "无")")
                // api.assetUrl / plugin.json 的 icon 走的是同一条取资源路径，顺带自检
                if let iconName = e.manifest["icon"] as? String, iconName.contains(".") {
                    let u = PluginLoader.assetDataURL(id: e.id, name: iconName)
                    Log.info("  asset: \(e.id)/\(iconName) → \(u.count) 字符 data URL")
                }
            }
            // 自检：图标生成必须在后台线程也能跑（输入时才不会卡住主线程）
            DispatchQueue.global(qos: .userInitiated).async {
                let icon = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
                Log.info("  background icon ok: \(IconUtil.pngBase64(icon).count) chars")
            }
        }
        if let zip = env["YA_IMPORT"] {
            do {
                let result = try PluginImporter.importZip(at: URL(fileURLWithPath: zip))
                Log.info("imported: \(result.id) \(result.versionChange) (\(result.kind))")
                Log.info("plugins now: \(names())")
            } catch {
                Log.info("import failed: \(error.localizedDescription)")
            }
        }
        if let id = env["YA_DELETE"] {
            do {
                try PluginImporter.delete(id: id)
                Log.info("deleted: \(id)")
                Log.info("plugins now: \(names())")
            } catch {
                Log.info("delete failed: \(error.localizedDescription)")
            }
        }
        if let raw = env["YA_INSTALL"], let url = URL(string: raw) {
            Log.info("install from url: \(raw)")
            DeepLinkHandler.installFromURL(url, requireConfirm: false)
        }
    }
}
