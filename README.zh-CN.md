# ya —— macOS 上的轻量启动器

**[English version: README.md](./README.md)**

ya 是一个 macOS 全局启动器，⌥Space 呼出浮动面板，可搜索启动本机应用，也可进入插件完成具体任务。
外壳用 Swift/AppKit 保证原生体验，界面与插件生态用 Web 技术降低开发成本。

- **外壳**：原生 Swift / AppKit（快捷键、面板、应用索引、图标、剪贴板、存储）
- **界面与插件**：`WKWebView` + TypeScript / CSS
- **环境要求**：macOS 13.5+、Swift 5.8，用 SwiftPM 构建（无 `.xcodeproj`）
- **作者**：zhouyefei

---

## 功能特性

- **应用搜索** —— 磁盘缓存 + 后台重扫 + 目录监听，第一次按键就能命中全部应用；五级相关性排序，支持**拼音**匹配（前缀 > 全拼前缀 > 包含 > 拼音包含 > 首字母子序列）
- **插件体系** —— HTML/TS/CSS 插件，热加载，样式隔离，每个插件独立键值存储
- **插件管理** —— 导入 / 删除 zip、自定义关键字、一眼看见关键字冲突
- **剪贴板历史** —— 文本与图片，自动去重，支持收藏，容量有上限
- **最近使用** —— 应用与插件共用一份时间线
- **深浅色** —— 默认跟随系统，也可在设置里强制指定
- **快捷键可配置** —— 在设置里录制，默认 ⌥Space
- **诊断导出** —— 一键导出版本、插件列表、冲突项与近期日志

---

## 快速开始

```bash
./build.sh      # 先编译 TS（tsc --outFile），再 swift build -c release
./package.sh    # 组装 dist/ya.app（图标、Info.plist、ad-hoc 签名、lsregister）
./run.sh        # 以独立会话方式启动
./stop.sh       # 停止
```

然后按 **⌥Space**。

> `typescript` 必须是 5.x —— 6.x 移除了 `--outFile`。`tsc` / `node` 的路径写死在
> `build.sh`（以及 `PluginImporter.swift`）里，换机器要改。
>
> `run.sh` 会优先启动 `dist/ya.app`：只有 `.app` 包才注册了 `yatools://` 协议，
> 想让网页一键安装插件生效，就需要打包成 app。

---

## 使用方式

| 操作 | 结果 |
| --- | --- |
| `⌥Space` | 呼出 / 收起面板（可在设置里改） |
| 输入字母 | 搜索应用、插件以及 provider 返回的结果 |
| `关键字` + 空格 | 进入该插件（例如 `calc 2+2`） |
| 第一次 `Esc` | 退出插件 / 清空输入，面板保留 |
| 再一次 `Esc` | 收起面板 |
| 拖动顶部 12px 条 | 移动面板 |

只要不是主动按 Esc 退出，再次呼出面板会**回到上次使用的插件**。

---

## 编写插件

插件就是一个目录（或 zip）：`plugin.json` + 打包后的 `main.js`
（只有 `main.ts` 时，宿主会用本机 tsc 就地编译）。

```json
{
  "id": "calc",
  "keyword": "calc",
  "keywords": ["calc", "math"],
  "version": "1.0.0",
  "icon": "🧮",
  "minHostVersion": "0.1.0",
  "name": { "en": "Calculator", "zh": "计算器" },
  "description": { "en": "Evaluate an expression", "zh": "输入表达式计算" }
}
```

两种形态：

|  | 面板型插件（默认） | 结果提供者（`"provider": true`） |
| --- | --- | --- |
| 触发方式 | `关键字` + 空格 | 每次输入都询问一次 `onProvide(query, api)` |
| 渲染方 | 插件自己渲染 `container` | 宿主渲染 `ProviderItem[]` |
| 关键字 | 必填 | 可选 |

在插件管理页拖入 zip 即可安装；也可以发布 `yatools://install?url=<https 的 zip>` 链接，
实现网页一键安装。完整 API 见 **[`docs/plugin-api.md`](docs/plugin-api.md)**，
可复制的脚手架在同级的 `plugin/` 仓库，最小示例见 [`examples/hello`](examples/hello)。

---

## 目录结构

```
ya/
├── Package.swift          # SwiftPM：yaCore（library）+ ya（可执行文件）+ yaTests
├── Sources/ya/            # Swift 外壳（面板、应用索引、插件、剪贴板、设置等）
├── Sources/yaApp/         # 可执行入口 —— 只有一行 AppBootstrap.run()
├── Sources/ya/Web/        # 前端：index.html、shell.ts/css、bridge.ts
├── Tests/yaTests/         # XCTest
├── Tests/web/             # node:test + jsdom，直接跑真实的 shell.js
├── docs/plugin-api.md     # 插件 API 契约（API 变更时同步更新）
├── examples/hello/        # 示例插件
└── build.sh package.sh run.sh stop.sh test.sh
```

> Swift 的可执行 target 不能被 `import`，所以所有逻辑都放在 `yaCore` library 里，
> `main.swift` 只剩一行调用 —— 这样 XCTest 才跑得起来。

---

## 开发

```bash
./test.sh          # 全量：XCTest + 前端测试
./test.sh swift    # 只跑原生
./test.sh web      # 只跑前端（会先重新编译 shell.js）
```

调试用的环境变量：

```bash
YA_DEBUG=1              # 打印快捷键、应用索引来源与数量、插件关键字与冲突
YA_IMPORT=/path/a.zip   # 启动时导入一个插件
YA_DELETE=<plugin-id>   # 启动时删除指定插件
YA_INSTALL=<url>        # 免确认跑完整安装流程
```

两个最容易踩的坑：不可信字符串别用 `JSONSerialization.data`（它会抛 `try?` 挡不住的
ObjC 异常，请改用 `SafeJSON`）；别在主线程调用 `NSWorkspace.icon(forFile:)`
（会卡住输入，必须后台生成后异步推送）。更多坑见 `agent.md` 第 8 节。

---

## 数据与日志

| 内容 | 位置 |
| --- | --- |
| 插件 | `~/Library/Application Support/ya/plugins/<id>/` |
| 插件存储 | `~/Library/Application Support/ya/storage/` |
| 剪贴板历史 | `~/Library/Application Support/ya/clipboard.json` + `clipboard-images/` |
| 应用索引缓存 | `~/Library/Application Support/ya/app-cache.json` |
| 设置 / 最近使用 | `UserDefaults`（键名以 `ya.` 开头） |
| 日志 | `~/Library/Application Support/ya/ya.log` |

> 除文件日志外还有一份 500 行的内存环形缓冲，崩溃时靠它保留现场。

---

## 提交规范

提交信息一律用**英文**，Conventional Commits 简版：

```
<type>: <imperative summary under 72 chars>

- optional bullet: why, not what
```

提交前跑一次 `./test.sh`。完整约定见 `agent.md` 第 13 节。
