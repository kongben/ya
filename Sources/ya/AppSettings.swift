import Foundation

enum AppLanguage: String, CaseIterable {
    case auto // 跟随系统（默认）
    case en
    case zh
}

/// 界面外观。auto = 跟随系统（默认）。
///
/// 手动指定时不改 CSS：宿主面板的颜色由 `prefers-color-scheme` 决定，
/// 而它跟着 `NSApp.appearance` 走（见 Theme.swift），所以三种模式共用同一份样式表。
enum AppTheme: String, CaseIterable {
    case auto
    case light
    case dark

    /// 对应的 AppKit appearance 名；`nil` = 不设置（跟随系统）
    var appearanceName: String? {
        switch self {
        case .auto: return nil
        case .light: return "NSAppearanceNameAqua"
        case .dark: return "NSAppearanceNameDarkAqua"
        }
    }
}

/// 旧版（QuickLauncher 命名）数据迁移
enum LegacyMigrator {
    private static var done = false

    /// UserDefaults：quicklauncher.* → ya.*（幂等）
    static func migrateDefaults() {
        guard !done else { return }
        done = true
        let d = UserDefaults.standard
        let legacy = "quicklauncher."
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(legacy) {
            let newKey = "ya." + key.dropFirst(legacy.count)
            if d.object(forKey: newKey) == nil {
                d.set(d.object(forKey: key), forKey: newKey)
            }
        }
    }

    /// Application Support：~/Library/Application Support/QuickLauncher → ya（幂等）
    static func migrateAppSupport() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let newBase = home.appendingPathComponent("Library/Application Support/ya")
        let legacyBase = home.appendingPathComponent("Library/Application Support/QuickLauncher")
        if fm.fileExists(atPath: legacyBase.path), !fm.fileExists(atPath: newBase.path) {
            try? fm.createDirectory(at: newBase.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.moveItem(at: legacyBase, to: newBase)
        }
    }
}

import Carbon.HIToolbox

/// 全局呼出快捷键。keyCode 是虚拟键码（Carbon kVK_*），modifiers 是 Carbon 修饰键掩码。
struct HotKey: Equatable {
    var keyCode: UInt32 = UInt32(kVK_Space)
    var modifiers: UInt32 = UInt32(optionKey)

    /// 是否带了至少一个修饰键（纯字母/数字键当全局热键会吞掉正常输入，不允许）
    var hasModifier: Bool { modifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey) != 0 }

    /// 这些组合即使 RegisterEventHotKey 返回成功，按下时也会被系统截获
    /// （典型：⌘Space 属于聚焦搜索、⌃Space 是输入法切换），只能靠黑名单提前提醒
    var maybeSystemReserved: Bool {
        let cmd = UInt32(cmdKey), opt = UInt32(optionKey)
        let ctl = UInt32(controlKey), sh = UInt32(shiftKey)
        let reserved: [(UInt32, Int)] = [
            (cmd, kVK_Space), (cmd | opt, kVK_Space), (ctl, kVK_Space),
            (cmd, kVK_Tab), (cmd | sh, kVK_Tab),
            (cmd | sh, kVK_ANSI_3), (cmd | sh, kVK_ANSI_4), (cmd | sh, kVK_ANSI_5),
            (cmd, kVK_ANSI_Comma),
        ]
        return reserved.contains { $0.0 == modifiers && UInt32($0.1) == keyCode }
    }

    /// 用于界面展示，如 "⌥ Space"
    var displayString: String {
        var out = ""
        let flags = modifiers
        if flags & UInt32(controlKey) != 0 { out += "⌃" }
        if flags & UInt32(optionKey) != 0 { out += "⌥" }
        if flags & UInt32(shiftKey) != 0 { out += "⇧" }
        if flags & UInt32(cmdKey) != 0 { out += "⌘" }
        let name = KeyNameMap.name(keyCode: keyCode)
        return out.isEmpty ? name : out + " " + name
    }

    static let `default` = HotKey()
}

/// 虚拟键码 → 可读名称（只覆盖常用键，其余回退为 Key<code>）
enum KeyNameMap {
    static func name(keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default:
            if let ch = ansiChar(keyCode: keyCode) { return ch.uppercased() }
            return "Key\(keyCode)"
        }
    }

    private static func ansiChar(keyCode: UInt32) -> String? {
        let map: [Int: String] = [
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d",
            kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h",
            kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
            kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p",
            kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
            kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
            kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        return map[Int(keyCode)]
    }
}

/// 应用设置，持久化到 UserDefaults
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private init() {
        LegacyMigrator.migrateDefaults()
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: "ya.lang") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "ya.lang") }
    }

    /// 界面外观（默认跟随系统）
    var theme: AppTheme {
        get { AppTheme(rawValue: defaults.string(forKey: "ya.theme") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "ya.theme") }
    }

    var showDockIcon: Bool {
        get { defaults.bool(forKey: "ya.showDockIcon") }
        set { defaults.set(newValue, forKey: "ya.showDockIcon") }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "ya.launchAtLogin") }
        set { defaults.set(newValue, forKey: "ya.launchAtLogin") }
    }

    /// 全局呼出快捷键（默认 Option+Space）
    var hotKey: HotKey {
        get {
            // 只在这两个键都存在时采用自定义值，否则用默认（避免半截状态）
            let code = defaults.object(forKey: "ya.hotkey.keyCode") as? Int
            let mods = defaults.object(forKey: "ya.hotkey.modifiers") as? Int
            if let code = code, let mods = mods, mods > 0 {
                return HotKey(keyCode: UInt32(code), modifiers: UInt32(mods))
            }
            return .default
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: "ya.hotkey.keyCode")
            defaults.set(Int(newValue.modifiers), forKey: "ya.hotkey.modifiers")
        }
    }

    /// 面板位置（用户拖过就记住，下次呼出还在原地）；nil = 用默认的屏幕中上方。
    /// 存两个 Double 而不是 NSPoint：本文件只依赖 Foundation。
    var panelOrigin: (x: Double, y: Double)? {
        get {
            guard let x = defaults.object(forKey: "ya.panel.x") as? Double,
                  let y = defaults.object(forKey: "ya.panel.y") as? Double else { return nil }
            return (x, y)
        }
        set {
            if let p = newValue {
                defaults.set(p.x, forKey: "ya.panel.x")
                defaults.set(p.y, forKey: "ya.panel.y")
            } else {
                defaults.removeObject(forKey: "ya.panel.x")
                defaults.removeObject(forKey: "ya.panel.y")
            }
        }
    }

    /// 剪贴板历史上限（超出后丢弃最旧的未收藏条目）
    var clipboardLimit: Int {
        get {
            let v = defaults.object(forKey: "ya.clipboard.limit") as? Int
            let n = v ?? 100
            return (n >= 20 && n <= 500) ? n : 100
        }
        set { defaults.set(newValue, forKey: "ya.clipboard.limit") }
    }

    /// 解析后的界面语言（auto 时跟随系统首选语言，只有 zh* 走中文）
    func resolvedLanguage() -> String {
        switch language {
        case .auto:
            if let first = Locale.preferredLanguages.first, first.hasPrefix("zh") { return "zh" }
            return "en"
        case .en: return "en"
        case .zh: return "zh"
        }
    }

    /// 当前是否中文界面。提示语到处都要判一次，别再写 `resolvedLanguage() == "zh"`
    static var isZh: Bool { AppSettings.shared.resolvedLanguage() == "zh" }

    func clearUsageHistory() {
        defaults.removeObject(forKey: "ya.usage.apps")
        defaults.removeObject(forKey: "ya.usage.plugins")
    }
}
