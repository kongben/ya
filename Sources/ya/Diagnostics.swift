import Foundation

/// 诊断与反馈。
///
/// 内测阶段最难受的不是出 bug，而是**用户说不清出了什么 bug**——
/// 面板白屏、点了没反应、昨天还好好的。这里把三件事收口：
///
/// 1. 未捕获异常写日志（AppKit / KVO 那类 OC 异常，Swift 的 `fatalError` 抓不到，见下）
/// 2. 上次是否异常退出（启动时看标记文件，崩溃没留下痕迹也能知道"上次没正常退出"）
/// 3. 一键导出诊断信息（版本 / 系统 / 插件 / 冲突 / 数据规模 / 最近日志）
///
/// 关于 Swift 崩溃：`NSSetUncaughtExceptionHandler` 只接得住 `NSException`。
/// Swift 的强制解包、`fatalError`、数组越界走的是 `SIGTRAP`/`SIGILL`，会直接把进程带走，
/// 在 signal handler 里写日志又容易死锁在锁上（崩溃可能正发生在持锁时）。
/// 所以这里**不接信号**，这类崩溃靠第 2 条的"上次异常退出"兜住，再让用户导出日志。
enum Diagnostics {
    /// 上次启动的标记文件
    private static var markerURL: URL { AppPaths.file("last-launch.json") }

    struct LaunchMarker: Codable {
        var pid: Int32
        var startedAt: TimeInterval
        var version: String
        /// 正常退出时置 true；进程被杀 / 崩溃时来不及改，下次启动就能看出来
        var cleanExit: Bool
    }

    // MARK: - 启动 / 退出标记

    /// 启动时调用：写入「这次还没正常退出」的标记
    static func markLaunch() {
        write(LaunchMarker(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date().timeIntervalSince1970,
            version: NativeServices.appVersion,
            cleanExit: false
        ))
    }

    /// 正常退出时调用（`applicationWillTerminate`）
    static func markCleanExit() {
        var m = read() ?? LaunchMarker(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date().timeIntervalSince1970,
            version: NativeServices.appVersion,
            cleanExit: false
        )
        m.cleanExit = true
        write(m)
    }

    /// 上次进程是否没走到正常退出（崩溃 / 被强杀 / 断电）。首次安装返回 false
    static func previousLaunchWasAbnormal() -> Bool {
        guard let m = read() else { return false }
        return !m.cleanExit
    }

    // MARK: - 未捕获异常

    /// 装上 `NSException` 兜底。尽早调用（在 `AppBootstrap` 里）
    static func installCrashHandler() {
        NSSetUncaughtExceptionHandler { ex in
            let reason = ex.reason ?? ""
            let stack = ex.callStackSymbols.joined(separator: "\n")
            Log.crash("未捕获异常 \(ex.name.rawValue): \(reason)\n\(stack)")
        }
    }

    // MARK: - 诊断报告

    /// 组装诊断报告正文（不含日志，日志由 `export` 追加在后面）
    static func collect() -> String {
        var lines: [String] = []
        lines.append("ya 诊断报告")
        lines.append("生成时间: \(Self.timestamp(Date()))")
        lines.append("")
        lines.append("[运行环境]")
        lines.append("ya 版本: \(NativeServices.appVersion)")
        lines.append("系统: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("架构: \(machineArch())")
        lines.append("界面语言: \(AppSettings.shared.resolvedLanguage())")
        lines.append("呼出快捷键: \(AppSettings.shared.hotKey.displayString)")
        lines.append("Dock 图标: \(AppSettings.shared.showDockIcon ? "开" : "关")")
        lines.append("开机启动: \(AppSettings.shared.launchAtLogin ? "开" : "关")")
        lines.append("")
        lines.append("[上次退出]")
        lines.append(previousLaunchWasAbnormal() ? "异常（上次进程没有正常退出）" : "正常")
        lines.append("")
        lines.append(contentsOf: dataSection())
        lines.append("")
        lines.append(contentsOf: pluginSection())
        lines.append("")
        lines.append(contentsOf: conflictSection())
        return lines.joined(separator: "\n")
    }

    /// 把报告 + 最近日志写到一个文本文件，供用户发给开发者
    static func export(to url: URL) throws {
        var text = collect()
        text += "\n\n[最近日志]\n"
        text += Log.snapshot()
        text += "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        Log.info("诊断信息已导出: \(url.path)")
    }

    /// 导出时的默认文件名，如 `ya-diagnostics-20260926-042031.txt`
    static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "ya-diagnostics-\(f.string(from: Date())).txt"
    }

    // MARK: - 内部

    private static func dataSection() -> [String] {
        let fm = FileManager.default
        let root = AppPaths.root.path
        var out = ["[数据目录]", root.replacingOccurrences(
            of: fm.homeDirectoryForCurrentUser.path, with: "~"), ""]
        out.append("插件: \(Self.count(of: AppPaths.plugins)) 个")
        out.append("插件存储: \(Self.count(of: AppPaths.storage)) 个文件")
        out.append("剪贴板历史: \(size(AppPaths.file("clipboard.json")))")
        out.append("应用索引缓存: \(size(AppPaths.file("app-cache.json")))")
        out.append("关键字覆盖: \(size(AppPaths.file("keyword-overrides.json")))")
        out.append("日志文件: \(size(Log.fileURL))")
        return out
    }

    private static func pluginSection() -> [String] {
        var out = ["[已安装插件]"]
        let entries = PluginIndex.shared.entries()
        if entries.isEmpty {
            out.append("（无）")
            return out
        }
        for e in entries.sorted(by: { $0.id < $1.id }) {
            let kw = e.keywords.joined(separator: ", ")
            var line = "- \(e.id) v\(e.version.display) [\(e.source)] 关键字: \(kw.isEmpty ? "（全部被抢占）" : kw)"
            if e.features.isEmpty == false {
                let cmds = e.features.map { $0.cmd }.filter { !$0.isEmpty }.joined(separator: ", ")
                if !cmds.isEmpty { line += " 入口: \(cmds)" }
            }
            if let rival = e.conflictWith { line += " 主关键字被 \(rival) 抢占" }
            out.append(line)
        }
        return out
    }

    private static func conflictSection() -> [String] {
        var out = ["[关键字冲突]"]
        let list = PluginIndex.shared.conflicts()
        if list.isEmpty {
            out.append("（无）")
            return out
        }
        for c in list { out.append("- \(c.id) 的「\(c.keyword)」被 \(c.ownerId) 占用") }
        return out
    }

    private static func count(of dir: URL) -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.filter { !$0.hasPrefix(".") }.count
    }

    /// 文件体积的可读文案；不存在 / 空文件显示 "—"
    private static func size(_ url: URL) -> String {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? UInt64, n > 0 else { return "—" }
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    private static func machineArch() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    // MARK: - 标记文件读写

    private static func read() -> LaunchMarker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(LaunchMarker.self, from: data)
    }

    private static func write(_ m: LaunchMarker) {
        guard let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: markerURL)
    }
}
