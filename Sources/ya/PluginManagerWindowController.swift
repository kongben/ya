import Cocoa
import UniformTypeIdentifiers

/// 插件管理窗口：列表展示、关键字编辑、导入 zip、删除用户插件，每次操作后重载插件系统
final class PluginManagerWindowController: NSWindowController,
                                           NSTableViewDataSource,
                                           NSTableViewDelegate {
    private struct Entry {
        let id: String
        let name: String
        let keywords: [String]        // 生效中的关键字（被抢占的不在里面）
        let declaredKeywords: [String] // 插件声明的关键字
        let conflictWith: String      // 抢占者 id
        let source: String            // builtin / user
        let customized: Bool          // 是否被用户覆盖过关键字
        let version: PluginVersion    // plugin.json 的 version（未声明时为 "—"）
        let minHostVersion: PluginVersion // 插件要求的最低 ya 版本
        let updateUrl: String         // 声明后可「检查更新」

        var isConflicted: Bool { !conflictWith.isEmpty }
        /// 插件要求的 ya 版本比当前高：多半是手动拷进来的，用不了
        var isHostTooOld: Bool { PluginImporter.hostVersion < minHostVersion }
    }

    private var entries: [Entry] = []
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!

    private var zh: Bool { AppSettings.isZh }
    /// 建 UI 时的语言：与设置窗口同理，语言切换后本窗口要自己重建
    private var builtZh: Bool = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
        reloadEntries()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .yaSettingsChanged,
            object: nil
        )
    }

    /// 语言变了才重建（插件安装 / 删改也会发这个通知，那些走各自的数据刷新就行）
    @objc private func settingsDidChange() {
        guard zh != builtZh else { return }
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        buildUI()
        reloadEntries()
    }

    // MARK: - UI

    private func buildUI() {
        guard let window = window, let content = window.contentView else { return }
        let zh = self.zh
        builtZh = zh
        window.title = zh ? "插件管理" : "Plugin Manager"

        tableView = NSTableView()
        for (ident, title, width) in [
            ("name", zh ? "名称" : "Name", 130.0),
            ("version", zh ? "版本" : "Version", 70.0),
            ("keyword", zh ? "关键字（双击编辑，逗号分隔）" : "Keyword (double-click, comma separated)", 200.0),
            ("conflict", zh ? "冲突" : "Conflict", 100.0),
            ("source", zh ? "来源" : "Source", 70.0),
        ] as [(String, String, CGFloat)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ident))
            col.title = title
            col.width = width
            col.isEditable = ident == "keyword"
            tableView.addTableColumn(col)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)

        let buttonStack = NSStackView()
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        for (title, sel) in [
            (zh ? "导入压缩包…" : "Import ZIP…", #selector(importPlugin)),
            (zh ? "检查更新" : "Check Update", #selector(checkUpdate)),
            (zh ? "删除" : "Delete", #selector(deletePlugin)),
            (zh ? "重置关键字" : "Reset Keyword", #selector(resetKeyword)),
            (zh ? "打开插件目录" : "Open Plugins Folder", #selector(openFolder)),
            (zh ? "重新加载" : "Reload", #selector(reloadPluginSystem)),
        ] as [(String, Selector)] {
            let b = NSButton(title: title, target: self, action: sel)
            buttonStack.addArrangedSubview(b)
        }
        content.addSubview(buttonStack)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),

            buttonStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttonStack.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - 数据

    private func reloadEntries() {
        entries = PluginIndex.shared.entries().map { e in
            let name = PluginIndex.text(of: e.manifest["name"])
            return Entry(
                id: e.id,
                name: name.isEmpty ? e.id : name,
                keywords: e.keywords,
                declaredKeywords: e.declaredKeywords,
                conflictWith: e.conflictWith ?? "",
                source: e.source,
                customized: PluginIndex.shared.override(for: e.id) != nil,
                version: e.version,
                minHostVersion: e.minHostVersion,
                updateUrl: e.updateUrl
            )
        }
        tableView?.reloadData()
        let zh = self.zh
        let builtin = entries.filter { $0.source == "builtin" }.count
        let user = entries.filter { $0.source == "user" }.count
        let conflicts = PluginIndex.shared.conflicts().count
        var summary = zh
            ? "共 \(entries.count) 个插件（内置 \(builtin) / 用户 \(user)）"
            : "\(entries.count) plugins (built-in \(builtin) / user \(user))"
        if conflicts > 0 {
            summary += zh ? " · ⚠️ \(conflicts) 处关键字冲突" : " · ⚠️ \(conflicts) keyword conflicts"
        }
        let tooOld = entries.filter { $0.isHostTooOld }.count
        if tooOld > 0 {
            summary += zh
                ? " · ⚠️ \(tooOld) 个插件需要更新的 ya（悬停看版本号）"
                : " · ⚠️ \(tooOld) plugin(s) need a newer ya (hover for version)"
        }
        statusLabel?.stringValue = summary
    }

    /// 悬停整行时说明「要 ya ≥ x，当前是 y」——版本列只放得下一个 ⚠️
    func tableView(_ tableView: NSTableView,
                   toolTipFor cell: NSCell,
                   rect: NSRectPointer,
                   tableColumn: NSTableColumn?,
                   row: Int,
                   mouseLocation: NSPoint) -> String {
        guard row < entries.count else { return "" }
        let e = entries[row]
        guard e.isHostTooOld else { return "" }
        return zh
            ? "需要 ya \(e.minHostVersion.display) 或更高，当前 \(PluginImporter.hostVersion.display)——请升级 ya"
            : "Requires ya \(e.minHostVersion.display) or newer (you have \(PluginImporter.hostVersion.display)) — please update ya"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView,
                   objectValueFor tableColumn: NSTableColumn?,
                   row: Int) -> Any? {
        guard row < entries.count else { return nil }
        let e = entries[row]
        switch tableColumn?.identifier.rawValue {
        case "version":
            return e.isHostTooOld ? e.version.display + " ⚠️" : e.version.display
        case "keyword":
            let text = e.declaredKeywords.joined(separator: ", ")
            return e.customized ? text + " ✎" : text
        case "conflict":
            guard e.isConflicted else { return "—" }
            return zh ? "被 \(e.conflictWith) 占用" : "taken by \(e.conflictWith)"
        case "source":
            return e.source == "builtin" ? (zh ? "内置" : "Built-in") : (zh ? "用户" : "User")
        default: return e.name
        }
    }

    /// 双击关键字列即可自定义（多个别名用逗号分隔）
    func tableView(_ tableView: NSTableView,
                   setObjectValue object: Any?,
                   for tableColumn: NSTableColumn?,
                   row: Int) {
        guard tableColumn?.identifier.rawValue == "keyword", row < entries.count else { return }
        let id = entries[row].id
        let raw = (object as? String) ?? ""
        let list = raw.components(separatedBy: ",")
        let normalized = PluginIndex.normalize(list)
        guard !normalized.isEmpty else {
            note(zh ? "关键字不能为空，已撤销本次修改" : "Keyword cannot be empty — change discarded")
            reloadEntries()
            return
        }
        PluginIndex.shared.setKeywords(list, for: id)
        PluginIcon.invalidate()
        reloadEntries()
        NotificationCenter.default.post(name: .yaSettingsChanged, object: nil)

        if let conflict = PluginIndex.shared.conflicts().first(where: { $0.id == id }) {
            note(zh
                ? "已保存，但关键字 \(conflict.keyword) 与「\(conflict.ownerId)」冲突，该关键字暂不生效"
                : "Saved, but keyword \"\(conflict.keyword)\" conflicts with \"\(conflict.ownerId)\" and is disabled")
        } else {
            note(zh ? "关键字已更新：\(normalized.joined(separator: ", "))" : "Keyword updated: \(normalized.joined(separator: ", "))")
        }
    }

    // MARK: - 操作

    @objc private func importPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = zh ? "选择插件压缩包（.zip）" : "Choose a plugin archive (.zip)"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType.zip]
        } else {
            panel.allowedFileTypes = ["zip"]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try PluginImporter.importZip(at: url)
            finishOperation()
            selectRow(withId: result.id)
            var msg = describe(result)
            if let conflict = PluginIndex.shared.conflicts().first(where: { $0.id == result.id }) {
                msg += zh
                    ? "（⚠️ 关键字 \(conflict.keyword) 与「\(conflict.ownerId)」冲突）"
                    : " (⚠️ keyword \"\(conflict.keyword)\" conflicts with \"\(conflict.ownerId)\")"
            }
            note(msg)
        } catch {
            alert(error.localizedDescription)
            finishOperation()
        }
    }

    /// 导入结果的中文/英文描述，重点是说清版本变化
    private func describe(_ r: PluginImportResult) -> String { r.localizedSummary }

    /// 检查选中插件的远端更新（需要 plugin.json 声明 updateUrl）
    @objc private func checkUpdate() {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else {
            note(zh ? "请先选择一个插件" : "Select a plugin first")
            return
        }
        let e = entries[row]
        guard let url = URL(string: e.updateUrl), !e.updateUrl.isEmpty else {
            note(zh ? "「\(e.name)」没有声明 updateUrl，无法检查更新"
                    : "\"\(e.name)\" has no updateUrl declared")
            return
        }
        note(zh ? "正在检查更新…" : "Checking for updates…")
        PluginUpdater.check(id: e.id, updateURL: url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .upToDate(let v):
                self.note(self.zh ? "已是最新版（\(v.display)）" : "Up to date (\(v.display))")
            case .failed(let reason):
                self.note((self.zh ? "检查更新失败：" : "Update check failed: ") + reason)
            case .available(let release):
                self.offerUpdate(entry: e, release: release)
            }
        }
    }

    private func offerUpdate(entry: Entry, release: PluginUpdater.Release) {
        // 没有下载地址时只公告版本，让用户自己去拿包
        guard let zip = release.zipURL else {
            note(zh ? "发现新版本 \(release.version.display)，可手动下载安装"
                    : "Version \(release.version.display) is available (download it manually)")
            return
        }
        let ok = Alert.confirm(
            title: zh ? "发现新版本" : "Update available",
            info: zh
                ? "「\(entry.name)」\(entry.version.display) → \(release.version.display)，是否更新？"
                : "\"\(entry.name)\" \(entry.version.display) → \(release.version.display). Update now?",
            confirm: zh ? "更新" : "Update")
        guard ok else { return }
        installFromRemote(zip, id: entry.id)
    }

    /// 从远端 zip 更新（与 DeepLinkHandler 同一套下载逻辑，这里简化为直接导入）
    private func installFromRemote(_ remote: URL, id: String) {
        note(zh ? "正在下载 \(remote.lastPathComponent)…" : "Downloading…")
        var request = URLRequest(url: remote, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = "GET"
        URLSession.shared.downloadTask(with: request) { [weak self] tmp, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let tmp = tmp, error == nil else {
                    self.note((self.zh ? "下载失败：" : "Download failed: ")
                              + (error?.localizedDescription ?? ""))
                    return
                }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ya-update-\(UUID().uuidString).zip")
                defer { try? FileManager.default.removeItem(at: dest) }
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    let result = try PluginImporter.importZip(at: dest)
                    self.finishOperation()
                    self.selectRow(withId: result.id)
                    self.note(self.describe(result))
                } catch {
                    self.alert(error.localizedDescription)
                }
            }
        }.resume()
    }

    @objc private func deletePlugin() {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else {
            note(zh ? "请先选择一个插件" : "Select a plugin first")
            return
        }
        let e = entries[row]
        // 删除是不可逆操作，必须确认
        let ok = Alert.confirm(
            title: zh ? "删除插件？" : "Delete plugin?",
            info: zh
                ? "「\(e.name)」（\(e.id)）将被永久删除，此操作不可撤销。"
                : "\"\(e.name)\" (\(e.id)) will be permanently deleted. This cannot be undone.",
            confirm: zh ? "删除" : "Delete")
        guard ok else { return }

        do {
            try PluginImporter.delete(id: e.id)
            PluginIndex.shared.clearOverride(for: e.id) // 一并清掉关键字覆盖，避免留下悬挂记录
            finishOperation()
            note(zh ? "已删除插件：\(e.id)" : "Deleted plugin: \(e.id)")
        } catch {
            alert(error.localizedDescription)
            finishOperation()
        }
    }

    @objc private func resetKeyword() {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else {
            note(zh ? "请先选择一个插件" : "Select a plugin first")
            return
        }
        let id = entries[row].id
        PluginIndex.shared.clearOverride(for: id)
        PluginIcon.invalidate()
        finishOperation()
        note(zh ? "已恢复 plugin.json 中的关键字" : "Keyword reset to plugin.json value")
    }

    private func selectRow(withId id: String) {
        guard let row = entries.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(PluginLoader.userDirectory())
    }

    @objc private func reloadPluginSystem() {
        finishOperation()
        note(zh ? "插件系统已重新加载" : "Plugin system reloaded")
    }

    /// 每次操作后：刷新列表 + 通知宿主重载界面（清空前端插件缓存、重新读取 manifest）
    private func finishOperation() {
        reloadEntries()
        NotificationCenter.default.post(name: .yaSettingsChanged, object: nil)
    }

    private func note(_ text: String) {
        statusLabel.stringValue = text
    }

    private func alert(_ text: String) {
        Alert.show(title: zh ? "操作失败" : "Operation failed", info: text, style: .warning)
    }
}
