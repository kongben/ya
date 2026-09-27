import Foundation

/// Web 资源目录定位：
/// - 打包成 .app 后：Contents/Resources/Web
/// - 开发期裸二进制：SPM 资源包 ya_ya.bundle/Web
enum AppResources {
    /// 单测用的替换 Web 根目录（指向临时目录里的假插件/假 index.html）。
    static var webRootOverride: URL?

    static var webRoot: URL? {
        if let override = webRootOverride { return override }
        let fm = FileManager.default
        let packaged = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Web")
        if fm.fileExists(atPath: packaged.path) { return packaged }
        return Bundle.module.resourceURL?.appendingPathComponent("Web")
    }
}
