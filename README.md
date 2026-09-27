# ya — a tiny launcher for macOS

> 中文说明：每个章节在英文正文后附「中文」小节（English first, Chinese after each section）。

A global launcher in the spirit of uTools: press **⌥Space** to summon a floating panel,
search and launch local apps, or jump straight into a plugin.

- **Shell**: native Swift / AppKit (hotkey, panel, app index, icons, clipboard, storage)
- **UI & plugins**: `WKWebView` + TypeScript / CSS
- **Requires**: macOS 13.5+, Swift 5.8, built with SwiftPM (no `.xcodeproj`)
- **Author**: zhouyefei

**中文**：ya 是一个 macOS 全局启动器，⌥Space 呼出浮动面板，可搜索启动本机应用，也可进入插件完成具体任务。外壳用 Swift/AppKit 保证原生体验，界面与插件生态用 Web 技术降低开发成本。要求 macOS 13.5+、Swift 5.8，用 SwiftPM 构建。

---

## Features

- **App search** — disk cache + background rescan + directory watching, so the first
  keystroke hits everything; 5-level relevance ranking with **pinyin** matching
  (prefix > full-pinyin prefix > contains > pinyin contains > initials subsequence)
- **Plugin system** — HTML/TS/CSS plugins, hot-loaded, scoped CSS, per-plugin KV storage
- **Plugin manager** — import/delete zips, customise keywords, see keyword conflicts at a glance
- **Clipboard history** — text and images, dedup, favourites, size-capped
- **Usage timeline** — apps and plugins share one recent list
- **Light / dark** — follows the system, or force either one in Settings
- **Configurable hotkey** — recorded in Settings; ⌥Space by default
- **Diagnostics export** — one click dumps version, plugins, conflicts and recent logs

**中文**：应用搜索（磁盘缓存 + 后台重扫 + 目录监听，支持拼音匹配）、插件体系（热加载、样式隔离、独立键值存储）、插件管理（导入/删除/改关键字/看冲突）、剪贴板历史、最近使用时间线、跟随系统的深浅色、可配置的全局快捷键、一键导出诊断信息。

---

## Quick start

```bash
./build.sh      # compile TS (tsc --outFile) then swift build -c release
./package.sh    # assemble dist/ya.app (icon, Info.plist, ad-hoc signing, lsregister)
./run.sh        # start it as a detached session
./stop.sh       # stop it
```

Then press **⌥Space**.

> `typescript` must be 5.x — 6.x removed `--outFile`. The `tsc` / `node` paths are
> hardcoded in `build.sh` (and `PluginImporter.swift`), adjust them to your machine.

**中文**：先 `./build.sh` 编译前端与原生代码，再 `./package.sh` 组装 `dist/ya.app`，`./run.sh` 启动（setsid 脱离终端常驻），`./stop.sh` 停止。注意 TypeScript 必须是 5.x（6+ 移除了 `--outFile`），tsc / node 路径写死在 `build.sh` 里，换机器要改。

---

## Usage

| Action | Result |
| --- | --- |
| `⌥Space` | show / hide the panel (changeable in Settings) |
| type letters | search apps, plugins and provider results |
| `keyword` + space | enter that plugin (e.g. `calc 2+2`) |
| `Esc` (first) | leave the plugin / clear input, panel stays |
| `Esc` (again) | hide the panel |
| drag the top 12px strip | move the panel |

The panel **reopens on the plugin you were last using** unless you left it with `Esc`.

**中文**：⌥Space 呼出/收起面板（设置里可改）；输入即搜索；「关键字 + 空格」进入插件；Esc 第一级退出插件或清空输入、第二级才收起面板；面板没有标题栏，顶部 12px 拖拽条是唯一的拖动入口。只要不是主动按 Esc 退出，再次呼出会回到上次的插件。

---

## Writing a plugin

A plugin is a folder (or zip) with a `plugin.json` and a bundled `main.js`:

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

Two shapes:

|  | Panel plugin (default) | Provider (`"provider": true`) |
| --- | --- | --- |
| Triggered by | `keyword` + space | every keystroke, via `onProvide(query, api)` |
| Rendering | the plugin draws `container` | the host renders `ProviderItem[]` |
| Keyword | required | optional |

Install by dropping a zip into the plugin manager, or ship a
`yatools://install?url=<https zip>` link for one-click web install.
Full contract: **[`docs/plugin-api.md`](docs/plugin-api.md)**; a ready-to-copy
scaffold lives in the sibling `plugin/` repo.

**中文**：插件就是一个目录或 zip：`plugin.json` + 打包后的 `main.js`（只有 `main.ts` 时会用本机 tsc 就地编译）。形态分两种——接管面板型（关键字 + 空格进入，自己渲染）和结果提供者（每次搜索都问一次，由宿主渲染）。通过插件管理页导入 zip，或网页 `yatools://install?url=…` 一键安装。完整 API 见 `docs/plugin-api.md`，脚手架见同级的 `plugin/` 仓库。

---

## Project layout

```
ya/
├── Package.swift          # SwiftPM: yaCore (library) + ya (executable) + yaTests
├── Sources/ya/            # Swift shell (panel, app index, plugins, clipboard, settings…)
├── Sources/yaApp/         # executable entry — one line: AppBootstrap.run()
├── Sources/ya/Web/        # front end: index.html, shell.ts/css, bridge.ts
├── Tests/yaTests/         # XCTest
├── Tests/web/             # node:test + jsdom against the real shell.js
├── docs/plugin-api.md     # plugin API contract (keep in sync when the API changes)
├── examples/hello/        # sample plugin
└── build.sh package.sh run.sh stop.sh test.sh
```

> The executable target cannot be imported, so all logic lives in the `yaCore`
> library and `main.swift` only calls `AppBootstrap.run()` — that is what makes XCTest possible.

**中文**：`Sources/ya/` 是原生外壳，`Sources/ya/Web/` 是前端，`Tests/` 分原生与前端两套。因为 Swift 的可执行 target 不能被 import，所有逻辑都放在 `yaCore` library 里，`main.swift` 只剩一行调用，这样单测才跑得起来。

---

## Development

```bash
./test.sh          # everything: XCTest + web tests
./test.sh swift    # native only
./test.sh web      # front-end only (rebuilds shell.js first)
```

Debug switches on the binary:

```bash
YA_DEBUG=1              # hotkey, app-index source/count, plugin keywords and conflicts
YA_IMPORT=/path/a.zip   # import a plugin at launch
YA_DELETE=<plugin-id>   # delete a plugin at launch
YA_INSTALL=<url>        # run the full install flow without confirmation
```

Two rules that bite everyone: never use `JSONSerialization.data` on untrusted strings
(it throws ObjC exceptions that `try?` cannot catch — use `SafeJSON`), and never call
`NSWorkspace.icon(forFile:)` on the main thread (it stalls typing — generate in the
background and push asynchronously). More landmines are collected in `agent.md` §8.

**中文**：`./test.sh` 跑全量单测（可只跑 swift / web）。调试变量有 `YA_DEBUG`、`YA_IMPORT`、`YA_DELETE`、`YA_INSTALL`。两个最容易踩的坑：不可信字符串别用 `JSONSerialization.data`（会抛 `try?` 挡不住的 ObjC 异常，用 `SafeJSON`）；别在主线程取 `NSWorkspace.icon(forFile:)`（会卡住输入，必须后台生成异步推送）。更多坑见 `agent.md` 第 8 节。

---

## Data & logs

| What | Where |
| --- | --- |
| Plugins | `~/Library/Application Support/ya/plugins/<id>/` |
| Plugin storage | `~/Library/Application Support/ya/storage/` |
| Clipboard history | `~/Library/Application Support/ya/clipboard.json` + `clipboard-images/` |
| App index cache | `~/Library/Application Support/ya/app-cache.json` |
| Settings / usage | `UserDefaults` (keys prefixed `ya.`) |
| Log | `~/Library/Application Support/ya/ya.log` |

**中文**：插件、插件存储、剪贴板历史、应用索引缓存都在 `~/Library/Application Support/ya/` 下；设置与最近使用走 `UserDefaults`；日志在 `ya.log`（另有 500 行内存环形缓冲，崩溃时靠它保留现场）。

---

## Commit convention

Commit messages are written in **English**, Conventional-Commits style:

```
<type>: <imperative summary under 72 chars>

- optional bullet: why, not what
```

Run `./test.sh` before committing. See `agent.md` §13 for the full conventions.

**中文**：提交信息一律用英文，Conventional Commits 简版（`type: 简述`，正文只写「为什么」），提交前跑 `./test.sh`。完整约定见 `agent.md` 第 13 节。
