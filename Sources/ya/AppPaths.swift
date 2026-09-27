import Foundation

/// 应用数据目录：`~/Library/Application Support/ya`
///
/// 插件、插件存储、剪贴板历史、应用索引缓存、关键字覆盖表都写在这里。
/// 之前每个模块各自拼一遍 `homeDirectoryForCurrentUser + "Library/Application Support/ya"`，
/// 少写一个字符就会出现"数据落到了另一个目录"的幽灵问题，统一到这一处。
enum AppPaths {
    /// 单测用的替换根目录。非 nil 时 `root / plugins / storage / clipboardImages / file()`
    /// 全部改指向它，测试就不会碰到真实的用户数据（也不会跑旧版目录迁移）。
    /// 生产代码永远不设置它。
    static var rootOverride: URL?

    /// 根目录；首次访问时做一次旧版（QuickLauncher）目录迁移并建目录
    static var root: URL {
        if let override = rootOverride { return ensure(override) }
        LegacyMigrator.migrateAppSupport()
        return ensure(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ya")
        )
    }

    /// 用户插件目录
    static var plugins: URL { ensure(root.appendingPathComponent("plugins")) }
    /// 插件 KV 存储目录（与 plugins/ 分开，避免存储文件被当成插件扫描）
    static var storage: URL { ensure(root.appendingPathComponent("storage")) }
    /// 剪贴板缩略图目录
    static var clipboardImages: URL { ensure(root.appendingPathComponent("clipboard-images")) }

    /// 根目录下的文件（app-cache.json / clipboard.json / keyword-overrides.json…）
    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    @discardableResult
    private static func ensure(_ dir: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
