import Cocoa
import Carbon.HIToolbox

/// 快捷键录制控件：点一下进入录制态，按下组合键即保存。
/// 用本地事件监听器而不是 keyDown，这样不必抢 first responder，也不会被按钮的默认动作吃掉。
final class HotKeyRecorder: NSView {
    var onChange: ((HotKey) -> Void)?
    /// 录制过程中的提示（如"请搭配修饰键"），交给宿主显示，控件本身不排版额外文字
    var onHint: ((String) -> Void)?
    private(set) var hotKey: HotKey
    private var recording = false
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private let label = NSTextField(labelWithString: "")

    init(hotKey: HotKey) {
        self.hotKey = hotKey
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var zh: Bool { AppSettings.isZh }

    /// 外部改值（如"恢复默认"）：退出录制态并刷新显示，不触发 onChange
    func setHotKey(_ key: HotKey) {
        stopRecording()
        hotKey = key
        refresh()
    }

    private func refresh() {
        label.stringValue = recording
            ? (zh ? "按下快捷键…" : "Press shortcut…")
            : hotKey.displayString
        layer?.backgroundColor = recording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
        layer?.borderColor = recording ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        if recording { stopRecording(); return }
        startRecording()
    }

    private func startRecording() {
        recording = true
        refresh()
        // 录制期间吃掉所有按键，避免空格/回车触发窗口默认按钮
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handle(e)
            return nil
        }
        // 点到别处就退出录制
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            if let self = self, self.recording { self.stopRecording() }
            return e
        }
    }

    private func stopRecording() {
        recording = false
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        refresh()
    }

    private func handle(_ e: NSEvent) {
        if e.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        let mods = Self.carbonModifiers(from: e.modifierFlags)
        let isFnKey = (Int(e.keyCode) >= kVK_F1 && Int(e.keyCode) <= kVK_F20)
        if mods == 0 && !isFnKey {
            onHint?(zh ? "请搭配 ⌘ / ⌥ / ⌃ / ⇧（或按 Esc 取消）"
                       : "Add ⌘ / ⌥ / ⌃ / ⇧ (or Esc to cancel)")
            return
        }
        hotKey = HotKey(keyCode: UInt32(e.keyCode), modifiers: mods)
        stopRecording()
        onChange?(hotKey)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

extension Notification.Name {
    /// 快捷键已变更，需要重新注册全局热键
    static let yaHotKeyChanged = Notification.Name("yaHotKeyChanged")
    /// 请求隐藏面板（打开设置等窗口前发，面板层级比普通窗口高）
    static let yaHidePanel = Notification.Name("yaHidePanel")
    /// 快捷键已（重新）注册，展示文案需要刷新
    static let yaHotKeyRegistered = Notification.Name("yaHotKeyRegistered")
}
