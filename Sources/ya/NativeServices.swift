import Cocoa
import UniformTypeIdentifiers
import UserNotifications

/// 系统级原生能力封装（对应 uTools 的 utools 系统 API）
enum NativeServices {
    static let appName = "ya"
    static let appVersion = "0.1.0"

    // MARK: - 通知

    static func notify(body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in deliver(body) }
            case .authorized, .provisional:
                deliver(body)
            default:
                break // 用户拒绝授权时静默跳过，不打断插件
            }
        }
    }

    private static func deliver(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = appName
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 文件 / URL

    static func openPath(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: expand(path)))
    }

    static func openURL(_ url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    static func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expand(path))])
    }

    static func trashItem(_ path: String) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: expand(path)), resultingItemURL: nil)
    }

    static func beep() {
        NSSound.beep()
    }

    // MARK: - 路径

    static func path(_ name: String) -> String {
        let fm = FileManager.default
        func dir(_ search: FileManager.SearchPathDirectory) -> String {
            fm.urls(for: search, in: .userDomainMask).first?.path ?? ""
        }
        let appData = dir(.applicationSupportDirectory)
        switch name {
        case "home": return NSHomeDirectory()
        case "temp": return NSTemporaryDirectory()
        case "appData": return appData
        case "userData": return appData + "/ya"
        case "logs": return NSHomeDirectory() + "/Library/Logs"
        case "desktop": return dir(.desktopDirectory)
        case "documents": return dir(.documentDirectory)
        case "downloads": return dir(.downloadsDirectory)
        case "music": return dir(.musicDirectory)
        case "pictures": return dir(.picturesDirectory)
        case "videos": return dir(.moviesDirectory)
        case "exe": return ProcessInfo.processInfo.arguments.first ?? ""
        default: return ""
        }
    }

    // MARK: - 图标

    /// 支持：文件路径 / 扩展名（".txt"）/ "folder"
    /// 返回 base64 Data URL
    static func fileIcon(_ key: String) -> String {
        let icon: NSImage
        if key == "folder" {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else if key.hasPrefix("."), key.count > 1,
                  let type = UTType(filenameExtension: String(key.dropFirst())) {
            icon = NSWorkspace.shared.icon(for: type)
        } else {
            icon = NSWorkspace.shared.icon(forFile: expand(key))
        }
        // 必须走 IconUtil 重绘：直接改 image.size 不会缩小底层位图，
        // TIFF 里仍是 512px 表示，导出 base64 可达数百 KB（见 IconUtil 注释）
        let b64 = IconUtil.pngBase64(icon, size: NSSize(width: 32, height: 32))
        return b64.isEmpty ? "" : "data:image/png;base64," + b64
    }

    // MARK: - 设备与环境

    /// 设备唯一 ID（首次生成后持久化在 UserDefaults）
    static func nativeId() -> String {
        let key = "ya.nativeId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static func isDarkColors() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - 剪贴板

    static func clipboardText() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    /// 剪贴板中复制的文件/文件夹
    static func copiedFiles() -> [[String: Any]] {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return urls.map { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return [
                "name": url.lastPathComponent,
                "path": url.path,
                "isFile": !isDir,
                "isDirectory": isDir
            ]
        }
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
