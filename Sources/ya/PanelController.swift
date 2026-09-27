import Cocoa
import WebKit

/// 可以成为 key window 的无边框面板
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// `WKUserContentController` 会**强引用** script message handler，
/// 直接传 self 会形成 webView → userContentController → controller → webView 的循环引用。
/// 用一层弱引用代理打破它。
private final class WeakScriptMessageDelegate: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

final class PanelController: NSObject, WKScriptMessageHandler {
    private var panel: LauncherPanel!
    private var webView: WKWebView!
    private var bridgeDelegate: WeakScriptMessageDelegate!
    private let appSearcher = AppSearcher()
    private let clipboardManager = ClipboardManager()
    private let usageHistory = UsageHistory()
    private let pluginStorage = PluginStorage()
    /// 当前加载的插件 id（供 getPluginAsset 省略 id 时使用）
    private var activePluginId: String?

    func setup() {
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 480)
        panel = LauncherPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = true
        panel.hasShadow = true

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled") // 右键检查元素调试
        bridgeDelegate = WeakScriptMessageDelegate(self)
        config.userContentController.add(bridgeDelegate, name: "native")

        webView = WKWebView(frame: contentRect, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = self
        panel.contentView = webView

        clipboardManager.start()
        loadShell()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadShell),
            name: .yaSettingsChanged,
            object: nil
        )
        // 打开设置/插件管理等窗口前先收起面板：面板是 floating 级，会盖住普通窗口
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideFromNotice),
            name: .yaHidePanel,
            object: nil
        )
        // 快捷键变更后把新文案推给前端（底部提示条里写死了 Option+Space）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pushHotKeyToWeb),
            name: .yaHotKeyRegistered,
            object: nil
        )
        // 设置窗口里的「重置面板位置」
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetPanelPositionFromNotice),
            name: .yaResetPanelPosition,
            object: nil
        )
        // 手动改外观：面板正显示时 WebView 会自己跟着 NSApp.appearance 变，
        // 只有藏着的情况（改设置前面板会被收起）需要重载一次，下次呼出才是新配色
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChangedFromNotice),
            name: .yaThemeChanged,
            object: nil
        )
    }

    @objc private func themeChangedFromNotice() {
        guard !panel.isVisible else { return }
        reloadShell()
    }

    @objc private func hideFromNotice() { hide() }

    @objc private func pushHotKeyToWeb() {
        // SafeJSON.string 已经自带两侧的引号，这里不能再包一层 `"` ——
        // 否则推给前端的是 `"⌥ Space"`（含字面引号），底栏提示会多出一对引号
        let text = SafeJSON.string(AppSettings.shared.hotKey.displayString)
        webView.evaluateJavaScript("window.__setHotKey && window.__setHotKey(\(text))")
    }

    /// 面板当前是否可见（供菜单栏更新标题）
    var isPanelVisible: Bool { panel.isVisible }

    @objc private func reloadShell() {
        PluginIcon.invalidate() // 插件/关键字可能已变化，图标缓存作废
        shellLoadFailures = 0   // 这是用户改设置触发的主动重载，不算加载失败
        loadShell()
    }

    private func loadShell() {
        guard let webRoot = AppResources.webRoot else {
            Log.error("Web 资源目录不存在，界面无法加载")
            return
        }
        let indexURL = webRoot.appendingPathComponent("index.html")
        webView.loadFileURL(indexURL, allowingReadAccessTo: webRoot)
    }

    // MARK: - 白屏兜底

    /// 连续加载失败次数，加载成功后清零；超过 `maxLoadAttempts` 不再自愈，改为提示用户
    private var shellLoadFailures = 0
    private let maxLoadAttempts = 3
    private var bootCheckTask: DispatchWorkItem?

    /// 加载完成后延迟检查脚本有没有真的跑起来。
    /// 不立刻查：WKWebView 的 `didFinish` 只代表 HTML 落地，脚本执行还要一点时间
    private func scheduleBootCheck() {
        bootCheckTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.checkBooted() }
        bootCheckTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: task)
    }

    private func checkBooted() {
        webView.evaluateJavaScript("window.__yaScriptLoaded === true") { [weak self] ok, err in
            guard let self = self else { return }
            if let err = err {
                Log.error("检查界面就绪状态失败: \(err.localizedDescription)")
            }
            if ok as? Bool == true {
                self.shellLoadFailures = 0
                Log.info("界面就绪")
                return
            }
            // 脚本一行都没执行：典型是 shell.js 语法错误（坑 15 那种顶层重名）或资源缺失
            Log.error("界面脚本未执行（白屏）")
            self.recoverShell()
        }
    }

    /// 重载界面；重试次数用尽后弹提示，而不是无限重载
    private func recoverShell() {
        shellLoadFailures += 1
        guard shellLoadFailures < maxLoadAttempts else {
            let zh = AppSettings.isZh
            Alert.show(
                title: zh ? "界面加载失败" : "Interface failed to load",
                info: zh ? "连续 \(shellLoadFailures) 次加载界面失败，请重启 ya；若反复出现，可在菜单栏「导出诊断信息」后反馈。"
                         : "Failed to load the interface \(shellLoadFailures) times. Please restart ya; if it keeps happening, export diagnostics from the menu bar and report it.",
                style: .critical
            )
            return
        }
        loadShell()
    }

    /// 供状态栏「重新加载界面」手动触发：不算失败
    func reloadInterface() {
        shellLoadFailures = 0
        loadShell()
    }

    // MARK: - 显示/隐藏

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        position()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        webView.evaluateJavaScript("window.__onPanelShown && window.__onPanelShown()")
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// 调整面板高度（插件可用 setExpendHeight 扩展展示区）
    private func setPanelHeight(_ height: CGFloat) {
        let clamped = min(max(height, 160), 900)
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = clamped
        frame.origin.y = top - clamped
        panel.setFrame(frame, display: true)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        // 用户拖过就回原位；位置已经跑到屏幕外（换显示器 / 改分辨率）才回退到默认位
        if let saved = AppSettings.shared.panelOrigin {
            let origin = NSPoint(x: saved.x, y: saved.y)
            if keepsVisible(origin: origin, size: size, in: frame) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        panel.setFrameOrigin(
            NSPoint(x: frame.midX - size.width / 2,
                    y: frame.maxY - size.height - 120)
        )
    }

    /// 记住的位置至少还得有一大半落在可见区域内，否则等于"面板消失了"
    private func keepsVisible(origin: NSPoint, size: NSSize, in frame: NSRect) -> Bool {
        let visible = NSIntersectionRect(NSRect(origin: origin, size: size), frame)
        return visible.width > size.width * 0.5 && visible.height > size.height * 0.5
    }

    // MARK: - 拖动面板（坑 28：位置按锚点算，别累积增量）
    //
    // 前端只报「鼠标现在在屏幕哪个点」，这里按下时记下的锚点算出窗口该在哪。
    // 用绝对锚点而不是逐帧增量，原因有两个：
    // 1. 增量是前端用 clientX/clientY 算的，而窗口一动 clientX 会反向变一次，
    //    增量于是混进了「窗口自己刚才移动了多少」→ 正反馈来回抖；
    // 2. 增量会丢帧累积误差，绝对坐标则丢多少帧都不影响最终位置。

    /// 一次拖拽的锚点：按下那一刻的窗口原点 + 鼠标屏幕位置
    private var dragAnchor: (origin: NSPoint, mouse: NSPoint)?

    private func beginPanelDrag(mouseX: CGFloat, mouseY: CGFloat) {
        dragAnchor = (panel.frame.origin, NSPoint(x: mouseX, y: mouseY))
    }

    private func dragPanel(mouseX: CGFloat, mouseY: CGFloat) {
        guard let anchor = dragAnchor else { return }
        // 鼠标屏幕坐标向下为正，Cocoa 的窗口原点向上为正
        panel.setFrameOrigin(NSPoint(x: anchor.origin.x + (mouseX - anchor.mouse.x),
                                     y: anchor.origin.y - (mouseY - anchor.mouse.y)))
    }

    /// 松手才落盘：拖拽过程里每次移动都写 UserDefaults 会让窗口明显发顿
    private func endPanelDrag() {
        guard dragAnchor != nil else { return }
        dragAnchor = nil
        AppSettings.shared.panelOrigin = (Double(panel.frame.origin.x), Double(panel.frame.origin.y))
    }

    @objc private func resetPanelPositionFromNotice() {
        AppSettings.shared.panelOrigin = nil
        position()
        if panel.isVisible { panel.setFrame(panel.frame, display: true) }
    }

    // MARK: - JS Bridge

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "native",
              let dict = message.body as? [String: Any],
              let action = dict["action"] as? String else { return }
        let payload = dict["payload"] as? [String: Any] ?? [:]
        let result = handle(action: action, payload: payload)
        // id == 0 是「只发不等」的高频调用（拖拽），回包要再过一次主线程，会拖慢窗口移动
        if let id = dict["id"] as? Int, id > 0 { respond(id: id, result: result) }
    }

    private func respond(id: Int, result: Any) {
        // SafeJSON：自己实现的序列化器，不抛 ObjC 异常（见 SafeJSON 注释）
        let json = SafeJSON.string(result)
        webView.evaluateJavaScript("window.__bridgeResponse(\(id), \(json))")
    }

    // MARK: - 图标（异步推送）

    private func requestIcon(payload: [String: Any]) -> Any {
        // 兼容旧调用：直接传 path 视为应用图标
        let key = payload.str("key", default: "app:" + payload.str("path"))
        guard !key.isEmpty else { return NSNull() }

        if key.hasPrefix("plugin:") {
            let id = String(key.dropFirst("plugin:".count))
            if let cached = PluginIcon.cached(id: id) { return cached }
            let entry = PluginIndex.shared.entry(id: id)
            PluginIcon.request(id: id, entry: entry) { [weak self] b64 in
                self?.pushIcon(key: key, b64: b64)
            }
            return NSNull()
        }
        let path = key.hasPrefix("app:") ? String(key.dropFirst("app:".count)) : key
        if let cached = appSearcher.cachedIcon(path: path) { return cached }
        appSearcher.requestIcon(path: path) { [weak self] b64 in
            self?.pushIcon(key: "app:\(path)", b64: b64)
        }
        return NSNull()
    }

    private func pushIcon(key: String, b64: String) {
        guard !b64.isEmpty else { return }
        let k = SafeJSON.string(key)
        let v = SafeJSON.string(b64)
        webView.evaluateJavaScript("window.__iconReady && window.__iconReady(\(k), \(v))")
    }

    // MARK: - 关键字自定义

    private func setPluginKeyword(payload: [String: Any]) -> Any {
        let id = payload.str("id")
        guard !id.isEmpty else { return NSNull() }
        let raw = (payload.str("keyword"))
        let list = raw.components(separatedBy: ",")
        // 与插件自带关键字一致时清除覆盖，让 plugin.json 的后续改动继续生效。
        // 注意必须比对 manifest 里的原始关键字，不能拿 declaredKeywords（有覆盖时它就是覆盖值）
        let declared = PluginIndex.shared.manifestKeywords(id: id)
        if PluginIndex.normalize(list) == declared {
            PluginIndex.shared.clearOverride(for: id)
        } else {
            PluginIndex.shared.setKeywords(list, for: id)
        }
        PluginIcon.invalidate()
        NotificationCenter.default.post(name: .yaSettingsChanged, object: nil)
        return NSNull()
    }

    private func handle(action: String, payload: [String: Any]) -> Any {
        switch action {
        case "hide":
            hide()
            return NSNull()
        case "searchApps":
            return appSearcher.search(query: payload.str("query"))
        // 图标按 key 请求（"app:<path>" / "plugin:<id>"）：命中缓存同步返回，
        // 否则后台生成后由原生推送 __iconReady，避免主线程做磁盘 IO 卡住输入
        case "getIcon":
            return requestIcon(payload: payload)
        case "launchApp":
            let path = payload.str("path")
            if !path.isEmpty {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: path),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
            return NSNull()
        case "getClipboardHistory":
            // 结构化条目（文本/图片/文件），内含 id、是否收藏、是否带图
            return clipboardManager.items.map { $0.dict }
        case "getClipboardImage":
            return clipboardManager.imageDataURL(id: payload.str("id"))
        case "setClipboard":
            let text = payload.str("text")
            if !text.isEmpty { clipboardManager.copyTextForPlugin(text) }
            return NSNull()
        case "restoreClipboardItem":
            return clipboardManager.restore(id: payload.str("id"))
        case "toggleClipboardPin":
            clipboardManager.togglePin(id: payload.str("id"))
            return NSNull()
        case "removeClipboardItem":
            clipboardManager.remove(id: payload.str("id"))
            return NSNull()
        case "clearClipboard":
            clipboardManager.clear(keepingPinned: !(payload.bool("all")))
            return NSNull()
        case "listPlugins":
            // 带关键字（含别名/用户覆盖）、冲突标记与拼音索引，前端据此做内存搜索
            return PluginIndex.shared.listPayload()
        case "loadPlugin":
            let pid = payload.str("id")
            activePluginId = pid.isEmpty ? nil : pid
            return PluginLoader.load(id: pid)
        case "getPluginAsset":
            return PluginLoader.assetDataURL(
                id: payload.str("id", default: activePluginId ?? ""),
                name: payload.str("name")
            )
        case "setPluginKeyword":
            return setPluginKeyword(payload: payload)
        // ---- 系统类 ----
        case "showNotification":
            NativeServices.notify(body: payload.str("body"))
            return NSNull()
        case "openPath":
            NativeServices.openPath(payload.str("path"))
            return NSNull()
        case "openURL":
            NativeServices.openURL(payload.str("url"))
            return NSNull()
        case "showInFinder":
            NativeServices.showInFinder(payload.str("path"))
            return NSNull()
        case "trashItem":
            NativeServices.trashItem(payload.str("path"))
            return NSNull()
        case "beep":
            NativeServices.beep()
            return NSNull()
        case "getPath":
            return NativeServices.path(payload.str("name"))
        case "getFileIcon":
            return NativeServices.fileIcon(payload.str("path"))
        case "getNativeId":
            return NativeServices.nativeId()
        // 本机网卡 IP（插件自己拿不到；本地服务的访问地址每天都不一样，只能现取）
        case "getLocalIPs":
            return LocalIPs.payload()
        case "getAppInfo":
            return ["name": NativeServices.appName, "version": NativeServices.appVersion]
        case "isDarkColors":
            return NativeServices.isDarkColors()
        case "getHotKey":
            return AppSettings.shared.hotKey.displayString
        case "getClipboardText":
            return NativeServices.clipboardText()
        case "getCopiedFiles":
            return NativeServices.copiedFiles()

        // ---- 窗口类 ----
        case "showMainWindow":
            show()
            return NSNull()
        case "setPanelHeight":
            if let h = payload.int("height") { setPanelHeight(CGFloat(h)) }
            return NSNull()
        // 鼠标拖面板：前端只报鼠标的屏幕坐标，位置由锚点算出（坑 28）
        case "beginPanelDrag":
            beginPanelDrag(mouseX: payload.num("x"), mouseY: payload.num("y"))
            return NSNull()
        case "movePanel":
            dragPanel(mouseX: payload.num("x"), mouseY: payload.num("y"))
            return NSNull()
        case "endPanelDrag":
            endPanelDrag()
            return NSNull()

        // ---- 插件存储 ----
        case "dbGet":
            return pluginStorage.get(
                plugin: payload.str("plugin", default: "global"),
                key: payload.str("key")
            )
        case "dbSet":
            pluginStorage.set(
                plugin: payload.str("plugin", default: "global"),
                key: payload.str("key"),
                value: payload.str("value")
            )
            return NSNull()
        case "dbRemove":
            pluginStorage.remove(
                plugin: payload.str("plugin", default: "global"),
                key: payload.str("key")
            )
            return NSNull()

        case "getLocale":
            // 跟随系统首选语言（设置里可强制指定），只有中文（zh*）走中文，其余一律英文
            return AppSettings.shared.resolvedLanguage()
        case "getUsage":
            // 先清掉已不存在的插件 id，否则「最近使用」会被僵尸记录占住
            usageHistory.prunePlugins(keeping: Set(PluginIndex.shared.entries().map { $0.id }))
            // 应用与插件共用一条时间线（见 UsageHistory），前端照着顺序画就行
            return ["recent": usageHistory.recent()] as [String: Any]
        case "recordAppUsage":
            let name = payload.str("name")
            let path = payload.str("path")
            if !name.isEmpty && !path.isEmpty { usageHistory.recordApp(name: name, path: path) }
            return NSNull()
        case "recordPluginUsage":
            let id = payload.str("id")
            if !id.isEmpty { usageHistory.recordPlugin(id: id) }
            return NSNull()
        default:
            return NSNull()
        }
    }
}

// MARK: - WKNavigationDelegate（白屏兜底）

/// 面板是一个裸 WKWebView，加载失败时用户看到的就是一块透明/空白面板，
/// 既没有报错也没有日志——内测时这种"点了没反应"最难定位，所以在这里兜住三种情况。
extension PanelController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleBootCheck()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.error("界面加载失败: \(error.localizedDescription)")
        recoverShell()
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Log.error("界面加载失败(资源缺失): \(error.localizedDescription)")
        recoverShell()
    }

    /// 网页进程被系统回收（内存压力 / 崩溃）——Web 端不会有任何回调，只能靠这里
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.warn("网页进程被终止，重新加载界面")
        recoverShell()
    }
}

/// 桥接 payload 的取值 helper：每个 case 各写一遍 `payload["x"] as? String ?? ""` 太吵，
/// 而且漏写 `?? ""` 就把 nil 带回 JS 了。统一在这里取值。
private extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String { self[key] as? String ?? "" }
    /// 取不到或为空串时回退默认值
    func str(_ key: String, default fallback: String) -> String {
        let v = self[key] as? String ?? ""
        return v.isEmpty ? fallback : v
    }
    func int(_ key: String) -> Int? { self[key] as? Int }
    func bool(_ key: String) -> Bool { self[key] as? Bool ?? false }
    /// 坐标类：JS 的 Number 过来可能是 Int 也可能是 Double（Retina 下会有 .5），统一按 Double 取
    func num(_ key: String) -> CGFloat {
        CGFloat((self[key] as? NSNumber)?.doubleValue ?? 0)
    }
}
