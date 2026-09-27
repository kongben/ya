import Foundation

/// 调试日志。
///
/// GUI 进程的 stdout 是**块缓冲**的，只 `fputs` 不 `fflush` 在日志里根本看不到输出——
/// 之前每个文件各写一遍 `fputs(...); fflush(stdout)`，统一到这里。
///
/// 除了 stdout，这里还维护一份**内存环形缓冲**（最近 `capacity` 条）。原因很实际：
/// 进程崩溃或被强杀时磁盘上的东西往往来不及 flush，而诊断要的偏偏是最后一瞬间的现场——
/// 内存里的最后几百行才是能拿到的东西（诊断导出与崩溃兜底都从这里取）。
enum Log {
    /// 环形缓冲容量（约 500 行，够覆盖一次异常前的全部上下文）
    static let capacity = 500

    /// 单份日志超过这个体积就截断重写（只留缓冲里的内容），避免长期运行后无限增长
    private static let maxFileBytes: UInt64 = 512 * 1024

    /// 是否落盘。单测里关掉，避免写到真实的用户目录
    static var fileEnabled = true

    /// 日志文件：`~/Library/Application Support/ya/ya.log`
    static var fileURL: URL { AppPaths.file("ya.log") }

    private static let lock = NSLock()
    private static var ring: [String] = []
    private static var fd: Int32 = -1

    static func info(_ s: String) { write("INFO", s) }
    static func warn(_ s: String) { write("WARN", s) }
    static func error(_ s: String) { write("ERROR", s) }

    /// 崩溃 / 未捕获异常专用。写完立即确保落盘，因为下一秒进程可能就没了
    static func crash(_ s: String) {
        write("CRASH", s)
        syncToDisk()
    }

    /// 内存缓冲里的日志（诊断导出用）。`limit > 0` 时只取最近这么多条
    static func snapshot(limit: Int = 0) -> String {
        lock.lock()
        let all = ring
        lock.unlock()
        let picked = limit > 0 ? Array(all.suffix(limit)) : all
        return picked.joined(separator: "\n")
    }

    /// 当前缓冲条数（单测与诊断摘要用）
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ring.count
    }

    /// 单测用：清空缓冲并关闭日志文件句柄
    static func reset() {
        lock.lock()
        ring = []
        lock.unlock()
        closeFile()
    }

    // MARK: - 内部

    private static func write(_ level: String, _ s: String) {
        let line = "\(stamp()) [\(level)] \(s)"
        fputs(line + "\n", stdout)
        fflush(stdout)
        lock.lock()
        ring.append(line)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        lock.unlock()
        appendToDisk(line)
    }

    /// 时间戳在锁里生成：`DateFormatter` 不是线程安全的，而日志可能从任意线程打
    private static func stamp() -> String {
        lock.lock()
        defer { lock.unlock() }
        return fmt.string(from: Date())
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 用 POSIX 写而不是 `FileHandle`：后者在 macOS 10.15.4+ 把 `write` / `close` 改成了
    /// throwing 版本，写 `try?` 在旧签名上又会报 "no calls to throwing functions" 警告——
    /// 构建要求零警告，直接走 Darwin 最省事，也没有 SDK 差异问题。
    private static func appendToDisk(_ line: String) {
        guard fileEnabled else { return }
        if fd < 0 { fd = Darwin.open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return }
        rotateIfNeeded()
        let bytes = Array((line + "\n").utf8)
        _ = Darwin.write(fd, bytes, bytes.count)
    }

    /// 超限就丢弃历史，只把当前缓冲重写回文件。不额外保留旧文件——
    /// 诊断在意的是最近的现场，留一堆 .1/.2 反而让用户不知道该发哪个
    private static func rotateIfNeeded() {
        guard fd >= 0 else { return }
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0, UInt64(st.st_size) > maxFileBytes else { return }
        closeFile()
        let text = snapshot()
        try? text.write(to: fileURL, atomically: false, encoding: .utf8)
        fd = Darwin.open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    /// POSIX 写本身不缓冲，这里只是把内核的文件元信息同步一次，确保进程猝死前数据已落地
    private static func syncToDisk() {
        guard fd >= 0 else { return }
        _ = Darwin.fsync(fd)
    }

    private static func closeFile() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}
