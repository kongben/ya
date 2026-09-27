import Foundation

/// 远端更新检查。插件在 plugin.json 里声明 `updateUrl`，指向一个 JSON：
///
/// ```json
/// { "version": "1.2.0", "url": "https://example.com/plugin-1.2.0.zip" }
/// ```
///
/// `url` 可选：只想公告版本号、不想被自动下载时可以只给 version。
enum PluginUpdater {
    struct Release {
        let version: PluginVersion
        let zipURL: URL?
    }

    enum CheckResult {
        case upToDate(PluginVersion)      // 已是最新（或本地更新）
        case available(Release)           // 有更新
        case failed(String)               // 网络/解析失败
    }

    /// 对比本地版本与远端版本。completion 回主线程
    static func check(id: String, updateURL: URL, completion: @escaping (CheckResult) -> Void) {
        var request = URLRequest(url: updateURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failed(error.localizedDescription))
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = (json["version"] as? String) ?? (json["latest"] as? String),
                      !raw.isEmpty else {
                    completion(.failed(AppSettings.isZh ? "更新信息格式不正确" : "Malformed update info"))
                    return
                }
                let remote = PluginVersion(raw: raw)
                let local = PluginImporter.installedVersion(id: id) ?? .zero
                // 本地版本未知时也认为可更新——否则没写 version 的插件永远查不到更新
                guard remote > local || local.isUnknown else {
                    completion(.upToDate(local))
                    return
                }
                let zip = ["url", "downloadUrl", "download_url"]
                    .compactMap { json[$0] as? String }
                    .first
                    .flatMap { URL(string: $0) }
                completion(.available(Release(version: remote, zipURL: zip)))
            }
        }.resume()
    }
}
