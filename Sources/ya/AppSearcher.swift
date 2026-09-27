import Cocoa
import Darwin

/// 应用索引：启动即全量可用，之后只做内存过滤
///
/// 分层设计（app 列表几乎不变，所以把「扫盘」这件事从搜索路径上彻底摘掉）：
/// 1. **磁盘缓存**：`~/Library/Application Support/ya/app-cache.json`，启动时同步读入，
///    冷启动第一个字母就能搜到全部应用（以前要等后台扫描 1~2 秒，首搜是空的）
/// 2. **后台扫描**：启动后在 utility 队列重扫一次并写回磁盘；图标同时后台预热
/// 3. **目录监听**：用 DispatchSource 监听 4 个 Applications 目录，装/卸应用才重扫，
///    不再每 5 分钟定时轮询（另有 15 分钟兜底，防止监听失效）
/// 4. **搜索**：只做内存过滤 + 拼音评分，零 IO、零主线程阻塞
final class AppSearcher {
    private struct AppEntry {
        let name: String
        let nameLower: String
        let path: String
        let pinyinFull: String      // 全拼：腾讯会议 -> tengxunhuiyi
        let pinyinInitials: String  // 首字母：腾讯会议 -> txhy
    }

    private static let watchedDirs = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities"
    ]

    private var apps: [AppEntry] = []
    private var lastScan = Date.distantPast
    private var isScanning = false
    private var iconCache: [String: String] = [:]
    private let lock = NSLock()
    /// 兜底重扫间隔：正常靠目录监听驱动，这里只是监听失效时的保险
    private let scanInterval: TimeInterval = 900
    private let scanQueue = DispatchQueue(label: "com.ya.app.appScan", qos: .utility)
    /// 图标生成队列：与扫描队列分开，用户请求的图标不会被预热任务堵住
    private let iconQueue = DispatchQueue(label: "com.ya.app.icon", qos: .userInitiated)

    private var dirSources: [DispatchSourceFileSystemObject] = []
    private var rescanWork: DispatchWorkItem?

    init() {
        // 1) 先读磁盘缓存，保证启动即可搜；缓存为空（首次安装）才现场扫一次
        //    注意这里只扫目录、不预热图标，否则启动会被几百次图标 IO 卡住
        let persisted = loadPersisted()
        apps = persisted.isEmpty ? scanEntries() : persisted
        lastScan = Date()
        if persisted.isEmpty { savePersisted(apps) }
        debugLog("索引就绪：\(apps.count) 个应用（\(persisted.isEmpty ? "首次扫描" : "磁盘缓存")）")
        // 2) 后台刷新一次 + 预热图标
        scanQueue.async { [weak self] in self?.performScan() }
        // 3) 之后靠目录变化驱动
        installWatchers()
    }

    deinit {
        rescanWork?.cancel()
        for src in dirSources where !src.isCancelled { src.cancel() }
    }

    // MARK: - 扫描调度

    /// 启动时后台预热扫描（保留给外部手动触发）
    func warm() {
        scanQueue.async { [weak self] in self?.performScan() }
    }

    /// search() 里最多只是补一次后台扫描：没有数据、或距上次扫描已超过兜底间隔。
    /// 常规更新交给目录监听，这里不再是每 5 分钟的无谓轮询。
    private func scheduleScanIfNeeded() {
        lock.lock()
        let neverScanned = lastScan == Date.distantPast
        let stale = Date().timeIntervalSince(lastScan) > scanInterval
        guard (neverScanned || stale), !isScanning else { lock.unlock(); return }
        isScanning = true
        lock.unlock()
        scanQueue.async { [weak self] in self?.performScan() }
    }

    /// 完整扫描（后台队列）：换入结果 → 落盘 → 预热图标
    private func performScan() {
        let entries = scanEntries()
        lock.lock()
        apps = entries
        lastScan = Date()
        isScanning = false
        lock.unlock()

        savePersisted(entries)
        debugLog("后台扫描完成：\(entries.count) 个应用")
        // 后台预热图标：之后搜索时基本都能同步命中缓存，不会卡住输入
        preloadIcons(paths: entries.map { $0.path })
    }

    /// YA_DEBUG=1 时打印索引状态
    private func debugLog(_ s: String) {
        guard ProcessInfo.processInfo.environment["YA_DEBUG"] == "1" else { return }
        Log.info(s)
    }

    /// 只枚举目录并生成索引（不含图标 IO），同步/后台调用均可
    private func scanEntries() -> [AppEntry] {
        var paths: [String] = []
        for dir in Self.watchedDirs {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for item in items where item.hasSuffix(".app") {
                    paths.append(dir + "/" + item)
                }
            }
        }
        let entries = paths.sorted().map { path -> AppEntry in
            // 使用系统本地化显示名（如 Tencent Meeting → 腾讯会议），
            // 失败时回退到文件夹名
            let fm = FileManager.default
            let name = fm.displayName(atPath: path)
            let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let finalName = name.isEmpty || name == (path as NSString).lastPathComponent
                ? fallback
                : name
            let matchName = finalName + " " + fallback
            let (pyFull, pyInit) = Pinyin.transform(matchName)
            return AppEntry(
                name: finalName,
                nameLower: matchName.lowercased(),
                path: path,
                pinyinFull: pyFull,
                pinyinInitials: pyInit
            )
        }
        return entries
    }

    /// 内存过滤 + 拼音模糊匹配，按相关度排序，无 IO、无图标生成
    func search(query: String) -> [[String: Any]] {
        scheduleScanIfNeeded() // 只在还没有任何数据时补扫一次
        lock.lock()
        let snapshot = apps
        lock.unlock()

        let q = query.lowercased()
        guard !q.isEmpty else {
            return snapshot.prefix(12).map { ["name": $0.name, "path": $0.path] }
        }
        // 相关度：0 名称前缀 < 1 全拼前缀 < 2 名称包含 < 3 全拼包含 < 4 首字母模糊
        var scored: [(score: Int, index: Int, app: AppEntry)] = []
        for (i, app) in snapshot.enumerated() {
            let score: Int
            if app.nameLower.hasPrefix(q) { score = 0 }
            else if app.pinyinFull.hasPrefix(q) { score = 1 }
            else if app.nameLower.contains(q) { score = 2 }
            else if app.pinyinFull.contains(q) { score = 3 }
            else if Pinyin.isSubsequence(q, app.pinyinInitials) { score = 4 }
            else { continue }
            scored.append((score, i, app))
        }
        scored.sort { ($0.score, $0.index) < ($1.score, $1.index) }
        return scored.prefix(12).map { ["name": $0.app.name, "path": $0.app.path] }
    }

    // MARK: - 目录监听（替代定时轮询）

    private func installWatchers() {
        for dir in Self.watchedDirs {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend],
                queue: scanQueue
            )
            source.setEventHandler { [weak self] in
                // 安装/卸载会连续触发多次事件，防抖后只扫一次
                self?.scheduleRescan(delay: 1.5)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            dirSources.append(source)
        }
    }

    private func scheduleRescan(delay: TimeInterval) {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = Date().timeIntervalSince(self.lastScan) > 5
            self.lock.unlock()
            if stale { self.performScan() }
        }
        rescanWork = work
        scanQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 磁盘缓存

    private var cacheURL: URL { AppPaths.file("app-cache.json") }

    /// 启动时同步读入：冷启动第一个字母就能命中完整列表
    private func loadPersisted() -> [AppEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return list.compactMap { d in
            guard let name = d["name"], !name.isEmpty,
                  let path = d["path"], !path.isEmpty else { return nil }
            // 旧版本缓存没有拼音字段时现场补算，保证搜索一致
            var full = d["py"] ?? ""
            var initials = d["pyi"] ?? ""
            if full.isEmpty {
                let (f, i) = Pinyin.transform(name)
                full = f
                initials = i
            }
            return AppEntry(
                name: name,
                nameLower: d["nameLower"] ?? name.lowercased(),
                path: path,
                pinyinFull: full,
                pinyinInitials: initials
            )
        }
    }

    private func savePersisted(_ entries: [AppEntry]) {
        let payload = entries.map { e in
            ["name": e.name, "path": e.path, "nameLower": e.nameLower,
             "py": e.pinyinFull, "pyi": e.pinyinInitials]
        }
        // SafeJSON：应用名/路径来自文件系统，特殊字符会让 JSONSerialization 抛 ObjC 异常
        guard let data = SafeJSON.data(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - 图标

    /// 同步返回已缓存的图标；未命中返回 nil。
    /// 绝不在主线程做磁盘 IO —— 曾经的同步生成正是中文输入法下输入卡顿的元凶
    func cachedIcon(path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return iconCache[path]
    }

    /// 异步取图标：命中缓存立即回调，否则后台生成后回主线程回调（b64 可能为空串）
    func requestIcon(path: String, completion: @escaping (String) -> Void) {
        guard !path.isEmpty else {
            completion("")
            return
        }
        if let cached = cachedIcon(path: path) {
            completion(cached)
            return
        }
        iconQueue.async { [weak self] in
            guard let self else { return }
            let b64 = self.makeIcon(path: path)
            self.lock.lock()
            self.iconCache[path] = b64
            self.lock.unlock()
            DispatchQueue.main.async { completion(b64) }
        }
    }

    /// 后台把图标全部生成好（utility 队列，不阻塞输入）
    private func preloadIcons(paths: [String]) {
        for path in paths {
            if cachedIcon(path: path) != nil { continue }
            let b64 = makeIcon(path: path)
            lock.lock()
            iconCache[path] = b64
            lock.unlock()
        }
    }

    /// 生成 64px PNG base64（只应在后台队列调用）
    private func makeIcon(path: String) -> String {
        IconUtil.pngBase64(NSWorkspace.shared.icon(forFile: path))
    }
}
