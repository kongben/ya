import Cocoa

/// 处理 ya:// 深链
///   ya://ping                          → 仅回应（网页用来探测是否安装）
///   ya://install?url=<zip 的 https 地址> → 下载并导入插件
///   可选参数 &id=<插件 id>&version=<版本号>：已装且版本不低于它时直接跳过下载
final class DeepLinkHandler {
    private init() {}

    static func handle(url: URL) {
        // GUI 进程 stdout 是块缓冲的，必须 fflush
        Log.info("deep link: \(url.absoluteString)")
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host else { return }

        switch host {
        case "ping":
            Alert.show(title: "ya",
                       info: AppSettings.isZh
                        ? "ya 已安装，可以一键导入插件"
                        : "ya is installed, one-click plugin import is available")

        case "install":
            guard let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  let zipURL = URL(string: raw) else {
                fail("链接缺少 url 参数")
                return
            }
            guard isAllowed(zipURL) else {
                fail("只允许 https 链接（本地调试可用 http://localhost）")
                return
            }
            // 网页带上 id+version 时，先比对本地版本：已经够新就不用下载了
            let announcedId = comps.queryItems?.first(where: { $0.name == "id" })?.value
            let announced = comps.queryItems?.first(where: { $0.name == "version" })?.value
            if let pid = announcedId, !pid.isEmpty,
               let raw = announced, !raw.isEmpty,
               let local = PluginImporter.installedVersion(id: pid),
               local >= PluginVersion(raw: raw) {
                let zh = AppSettings.isZh
                showNotice(zh
                    ? "已是最新版（\(local.display)），无需安装"
                    : "Already up to date (\(local.display)) — nothing to install")
                return
            }
            installFromURL(zipURL, requireConfirm: true)

        default:
            break
        }
    }

    /// 从远端 zip 安装插件；requireConfirm=false 用于调试（环境变量 YA_INSTALL）
    static func installFromURL(_ zipURL: URL, requireConfirm: Bool) {
        if requireConfirm {
            let zh = AppSettings.isZh
            showWindow(
                title: zh ? "安装插件" : "Install plugin",
                lines: [
                    (zh ? "来源：" : "Source: ") + (zipURL.host ?? zipURL.absoluteString),
                    zipURL.absoluteString,
                    zh ? "即将从上述来源下载并安装插件，是否继续？"
                       : "A plugin will be downloaded and installed from the source above. Continue?",
                ],
                styles: [.medium, .secondary, .body],
                confirmTitle: zh ? "安装" : "Install",
                cancelTitle: zh ? "取消" : "Cancel",
                onConfirm: { downloadAndInstall(zipURL) }
            )
            return
        }
        downloadAndInstall(zipURL)
    }

    // MARK: - 私有

    /// 非模态提示窗口（只有一个"好"）。同样是绕开 runModal 被自动按掉的问题
    static func showNotice(_ message: String) {
        Log.info("notice: \(message)")
        let zh = AppSettings.isZh
        showWindow(
            title: "ya",
            lines: [message],
            styles: [.body],
            confirmTitle: zh ? "好" : "OK",
            cancelTitle: nil,
            onConfirm: {}
        )
    }

    /// 非模态确认窗口：不能用 NSAlert.runModal —— 在 AppleEvent 处理上下文里
    /// 它会被系统自动按掉默认按钮（实测 1.6s 内直接放行），等于没有确认。
    /// 独立窗口 + 显式按钮回调，必须真人点击才会继续。
    private static func showWindow(title: String,
                                   lines: [String],
                                   styles: [TextStyle],
                                   confirmTitle: String,
                                   cancelTitle: String?,
                                   onConfirm: @escaping () -> Void) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: cancelTitle == nil ? 130 : 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.center()
        win.level = .floating
        win.isReleasedWhenClosed = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        win.contentView?.addSubview(content)

        for (i, line) in lines.enumerated() {
            let label = NSTextField(wrappingLabelWithString: line)
            let style = i < styles.count ? styles[i] : .body
            switch style {
            case .medium:
                label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            case .secondary:
                label.font = NSFont.systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
            case .body:
                label.font = NSFont.systemFont(ofSize: 12)
            }
            label.preferredMaxLayoutWidth = 400
            content.addArrangedSubview(label)
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        if let cancelTitle = cancelTitle {
            let cancel = NSButton(title: cancelTitle, target: nil, action: nil)
            cancel.bezelStyle = .rounded
            cancel.keyEquivalent = "\u{1b}" // Esc
            cancel.action = #selector(Self.confirmCancelled(_:))
            cancel.target = Self.self
            cancel.widthAnchor.constraint(equalToConstant: 90).isActive = true
            buttons.addArrangedSubview(cancel)
        }
        let confirm = NSButton(title: confirmTitle, target: nil, action: nil)
        confirm.bezelStyle = .rounded
        confirm.hasDestructiveAction = false
        confirm.action = #selector(Self.confirmAccepted(_:))
        confirm.target = Self.self
        confirm.widthAnchor.constraint(equalToConstant: 90).isActive = true
        buttons.addArrangedSubview(confirm)

        content.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: win.contentView!.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: win.contentView!.trailingAnchor, constant: -16),
        ])

        // 记录回调，按钮触发时使用（objc action 是静态路由）
        pendingConfirm = onConfirm
        confirmWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("window shown: \(title)")
    }

    enum TextStyle { case medium, secondary, body }

    private static var confirmWindow: NSWindow?
    private static var pendingConfirm: (() -> Void)?

    @objc private static func confirmAccepted(_ sender: NSButton) {
        Log.info("user accepted install")
        let action = pendingConfirm
        dismissConfirm()
        action?()
    }

    @objc private static func confirmCancelled(_ sender: NSButton) {
        Log.info("user cancelled install")
        dismissConfirm()
    }

    private static func dismissConfirm() {
        confirmWindow?.orderOut(nil)
        confirmWindow = nil
        pendingConfirm = nil
    }

    private static func isAllowed(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return true }
        // 本地调试便利：允许 http://localhost 与 http://127.0.0.1
        if scheme == "http", let host = url.host, host == "localhost" || host == "127.0.0.1" { return true }
        return false
    }

    private static func downloadAndInstall(_ remote: URL) {
        Log.info("downloading: \(remote.absoluteString)")
        // 30s 超时 + 20MB 体积上限，避免被大文件或慢连接挂死
        var request = URLRequest(url: remote, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = "GET"
        URLSession.shared.downloadTask(with: request) { tmp, response, error in
            DispatchQueue.main.async {
                guard let tmp = tmp, error == nil else {
                    fail(error?.localizedDescription ?? "下载失败")
                    return
                }
                if let size = response?.expectedContentLength, size > 20 * 1024 * 1024 {
                    fail("插件包超过 20MB")
                    return
                }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ya-download-\(UUID().uuidString).zip")
                defer { try? FileManager.default.removeItem(at: dest) }
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    let result = try PluginImporter.importZip(at: dest)
                    Log.info("installed plugin: \(result.id) \(result.versionChange)")
                    // 通知宿主重载插件系统（刷新界面 + 重新读取 manifest）
                    NotificationCenter.default.post(name: .yaSettingsChanged, object: nil)
                    Alert.show(title: AppSettings.isZh ? "插件已安装" : "Plugin installed",
                               info: result.localizedSummary)
                } catch {
                    fail(error.localizedDescription)
                }
            }
        }.resume()
    }

    private static func fail(_ reason: String) {
        Log.info("failed: \(reason)")
        DispatchQueue.main.async {
            Alert.show(title: AppSettings.isZh ? "安装失败" : "Installation failed",
                       info: reason,
                       style: .warning)
        }
    }
}
