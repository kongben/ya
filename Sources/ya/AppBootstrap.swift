import Cocoa

/// 进程入口。
///
/// `Sources/yaApp/main.swift` 里只有一行 `AppBootstrap.run()`。
/// 为什么不直接在那边写启动代码：executable target 通过 `import yaCore` 只能看到
/// **public** 符号，而 AppDelegate 等一律是 internal（跨模块本就不该暴露）。
/// 把启动过程收进 yaCore，main.swift 就不用为了让可执行文件编译通过而把一堆类型改成 public。
public enum AppBootstrap {
    /// NSApplication.delegate 是 weak，必须用静态变量把 delegate 留住，
    /// 否则 run() 返回后它就被释放了（面板、菜单栏会一起失效）
    private static var delegate: AppDelegate?

    public static func run() {
        // 顺序不能反：先装崩溃兜底 → 再看上次是不是异常退出 → 最后才写本次的启动标记
        // （写标记会把 cleanExit 置 false，之后再读就只能读到"这次没退出"）
        Diagnostics.installCrashHandler()
        if Diagnostics.previousLaunchWasAbnormal() {
            Log.warn("上次进程未正常退出（崩溃或被强杀）")
        }
        Diagnostics.markLaunch()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        // 必须在建任何窗口之前：面板的颜色由 NSApp.appearance 决定（见 Theme.swift）
        Theme.apply()
        app.setActivationPolicy(.accessory) // 不显示 Dock 图标
        app.run()
    }
}
