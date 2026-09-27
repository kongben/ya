import Carbon.HIToolbox

/// 全局快捷键：呼出/隐藏面板。组合由 AppSettings 提供，可运行时重新注册。
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var toggle: () -> Void

    init(toggle: @escaping () -> Void) {
        self.toggle = toggle
    }

    /// 卸载全局热键与事件处理器（避免重复安装/退出后残留）
    private func uninstall() {
        if let hotKeyRef = hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }

    deinit { uninstall() }

    /// 注册当前设置里的快捷键。返回是否注册成功
    /// （失败通常是被系统或其它应用占用，例如 Cmd+Space 属于聚焦搜索）
    @discardableResult
    func install() -> Bool {
        uninstall() // 幂等：重复 install 不会重复注册
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData = userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.toggle()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x79_61_54_6C) /* 'yaTl' */, id: 1)
        let key = AppSettings.shared.hotKey
        // 事件处理器只装一次；这里可能重复调用，先按返回值判断热键本体是否注册成功
        let status = RegisterEventHotKey(
            key.keyCode,
            key.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr { hotKeyRef = nil }
        return status == noErr
    }
}
