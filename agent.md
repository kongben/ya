# ya — macOS 启动器（类 uTools）项目说明

> 面向 AI/新成员的快速上手文档。代码在 `ya/` 目录，本文所有路径相对于本文件所在目录。

## 1. 项目是什么

一个 macOS 全局启动器：**Option+Space** 呼出浮动面板，可以搜索并启动本机应用，也可以进入插件做计算、剪贴板历史等事情。

- 名字：**ya**，图标是小黄鸭，Bundle ID `com.ya.app`
- 技术栈：**Swift 原生外壳（AppKit）+ WKWebView 渲染前端**，插件用 HTML/TS/CSS 写
- 目标 macOS 13.5+，Swift 5.8，用 SwiftPM 构建（没有 .xcodeproj）

设计取舍：外壳（快捷键、面板、扫盘、图标、剪贴板、存储）用 Swift 保证原生体验；UI 与插件生态用 Web 保证开发成本低。

## 2. 目录结构

```
ya/
├── Package.swift                 # SPM：yaCore（library）+ ya（可执行文件）+ yaTests（XCTest）
├── Sources/ya/                   # Swift 源码 → target `yaCore`（见下表）
├── Sources/yaApp/main.swift      # 可执行文件入口，只有一行 AppBootstrap.run()
├── Sources/ya/Web/               # 前端：index.html + shell.ts/css + bridge.ts + plugins/
├── Tests/yaTests/                # 原生单测（XCTest，`@testable import yaCore`）
├── Tests/web/                    # 前端单测（node:test + jsdom，加载真实 shell.js）
├── examples/hello/               # 用户插件示例（含 hello.zip 可导入测试）
├── docs/plugin-api.md            # 插件 API 中文文档（对外契约，改 API 必改这里）
                                  # 另见根目录 plugin-agent.md：AI 生成/修改插件的行为准则
├── build.sh                      # tsc 编译 TS → swift build -c release
├── package.sh                    # 组装 dist/ya.app（图标/Info.plist/签名/lsregister）
├── test.sh                       # 跑全部单测：./test.sh [all|web|swift]
├── run.sh / stop.sh              # 启动（setsid 脱离终端常驻）/ 停止
└── tools/make_app_icon/          # 代码生成小黄鸭 .icns
```

> **为什么拆成 yaCore + ya**：Swift 的 executable target 不能被 `import`，
> 想跑 XCTest 就必须把逻辑放进 library。代价是 executable 只看得到 `public` 符号，
> 所以启动过程收在 `AppBootstrap`（yaCore 内），`Sources/yaApp/main.swift` 只剩一行调用。
> 打包时资源 bundle 名随之变成 `ya_yaCore.bundle`（见 package.sh 的 `CORE_BUNDLE`）。

Swift 源码职责：

| 文件 | 职责 |
| --- | --- |
| `AppBootstrap.swift` | 进程入口的**全部**逻辑（建 NSApplication、挂 delegate、设 activationPolicy）。`main.swift` 只有一行调用它，因为 executable 看不到 internal 符号 |
| `AppDelegate.swift` | URL scheme 注册、调试环境变量 |
| `PanelController.swift` | 无边框 NSPanel + WKWebView，**JS 桥接的唯一入口**；监听 `.yaHidePanel` / `.yaHotKeyRegistered` |
| `AppSearcher.swift` | 应用索引：磁盘缓存 + 后台扫描 + 目录监听 + 内存搜索 |
| `Pinyin.swift` | CFStringTransform 汉字转全拼/首字母 + 子序列模糊匹配 |
| `PluginLoader.swift` | 读插件目录（内置 + 用户合并）；插件 CSS 的相对 `url()` 内联成 data URL；`assetDataURL` 取插件资源 |
| `PluginIndex.swift` | 关键字解析/别名/用户覆盖/**冲突检测**/拼音索引 |
| `PluginIcon.swift` | 插件图标（自带图片 / emoji / 首字母生成） |
| `IconUtil.swift` | NSImage → 64px PNG base64（真正降采样） |
| `PluginImporter.swift` | zip 导入 / 删除（防 zip-slip、原子替换、tsc 编译、版本比对） |
| `PluginVersion.swift` / `PluginUpdater.swift` | 版本号解析与比较 / 远端 `updateUrl` 更新检查 |
| `PluginStorage.swift` | 按插件隔离的键值库 |
| `PluginManagerWindowController.swift` | 插件管理窗口（导入/删除/改关键字/冲突展示） |
| `UsageHistory.swift` | 最近使用（应用 + 插件共用一条时间线，各带 ts，上限 12；UserDefaults，含旧两数组迁移） |
| `ClipboardStore.swift` | 剪贴板历史的**纯数据层**：去重 / 收藏保护 / 上限裁剪 / 编解码（不碰 AppKit 与磁盘，有单测覆盖） |
| `ClipboardManager.swift` / `NativeServices.swift` | 剪贴板轮询 + 缩略图 IO（副作用部分） / 系统能力（通知/打开文件/Finder/图标…） |
| `HotKeyManager.swift` | Carbon RegisterEventHotKey（组合可配置，见 §9） |
| `HotKeyRecorder.swift` | 快捷键录制控件（本地事件监听，不抢 first responder） |
| `StatusBarController.swift` / `SettingsWindowController.swift` | 菜单栏图标与设置 |
| `DeepLinkHandler.swift` | `yatools://` / `ya://` 网页一键安装 |
| `SafeJSON.swift` | 自研 JSON 序列化（**不用 JSONSerialization.data**，见 §7） |
| `DuckIcon.swift` / `AppResources.swift` | 小黄鸭图标绘制 / Web 资源定位 |

前端：

| 文件 | 职责 |
| --- | --- |
| `Web/shell.ts` | 外壳主体：状态、插件调度（含 features 多入口）、键盘/输入事件、启动（~480 行） |
| `Web/types.ts` | 前端公共类型（只有类型声明，无运行时代码） |
| `Web/match.ts` | 多语言文案（`lang` / `t()` 定义在此）+ 插件/应用搜索匹配 |
| `Web/ui.ts` | 渲染：结果列表、二维布局、图标缓存、插件 CSS 注入、面板高度、面板拖拽 |
| `Web/edit.ts` | 输入框文本编辑（复制/粘贴/剪切/全选/撤销）+ 右键菜单 |
| `Web/bridge.ts` | `callBridge(action, payload)` → Promise，10s 超时兜底 |
| `AppPaths.swift` | **唯一**的应用数据目录入口（`~/Library/Application Support/ya` 及 plugins/storage/clipboard-images 子目录）；别再各处拼路径 |
| `Theme.swift` | 深浅色：`AppTheme(auto/light/dark)` → `NSApp.appearance`。auto = nil 交给系统；手动指定靠 appearance 驱动 WebView 的 `prefers-color-scheme`，**CSS 只有一份**，别再想 data-theme 第二套 |
| `Alert.swift` | 统一弹窗：`Alert.show(...)` / `Alert.confirm(...)`，内部处理 accessory 应用的 `activationPolicy` 临时切换 |
| `Log.swift` | `Log.info/warn/error/crash(...)`：stdout 是块缓冲的，必须 `fflush`。同时维护**内存环形缓冲**（500 行）并落盘 `ya.log`——崩溃时磁盘往往来不及 flush，能拿到的只有内存里那几百行 |
| `Diagnostics.swift` / `Diagnostics+Export.swift` | 诊断与反馈：未捕获异常兜底、上次是否异常退出（启动标记文件）、`collect()` 生成报告、`export(to:)` 导出。扩展文件只放保存面板等 AppKit 部分，本体保持纯 Foundation 以便单测 |
| `Web/index.html` / `shell.css` | 结构 / 深浅两套配色（`prefers-color-scheme` 跟随系统 + `--ya-*` 主题变量，见 §6.5） |
| `#dragbar`（index.html） | 顶部 12px 专用拖拽条：面板是 borderless 窗口没标题栏，它是唯一看得见的拖动入口；按下即拖（不走 4px 阈值） |

> **宿主已不内置任何插件**（原 calculator / clipboard 于 2026-09-25 移出，现为
> `~/Desktop/ya-plugin/` 下的独立脚手架工程）。`Web/plugins/` 目录已删除；
> `PluginLoader` 的 builtin 通道保留，以后要加内置插件放回 `Web/plugins/<id>/` 即可。

## 3. 运行时数据流

```
用户按呼出键（默认 ⌥Space，设置里可改，见 §9）
  → HotKeyManager(Carbon) → PanelController.show()
  → evaluateJavaScript("window.__onPanelShown()")  面板重置
用户在 input 输入
  → shell.ts 防抖(120ms；输入法组合态 220ms)
  → 命中插件关键字（含 features 的专属关键字）+空格？
      → loadPlugin → new Function(code)() → __registerPlugin
      → 入口切换时先 onFeature(cmd)，再 onQuery(arg, container, api, feature)
                         否则 → callBridge("searchApps") + 前端内存匹配插件
                              + 并发问所有 provider 插件的 onProvide(query)（300ms 超时/异常即停用）
                              → 渲染「provider / 插件 / 应用」三组（provider 在最前，单插件最多 3 条）
结果图标
  → callBridge("getIcon", {key}) → 命中缓存同步返回；否则后台生成后
    原生 evaluateJavaScript("window.__iconReady(key,b64)") 推送
```

### JS ↔ Swift 桥接协议

- JS → Swift：`window.webkit.messageHandlers.native.postMessage({ id, action, payload })`
- Swift → JS：`window.__bridgeResponse(id, data)`（响应）、`window.__iconReady(key, b64)`（异步图标推送）、`window.__setHotKey(text)`（快捷键文案变更）
- Swift 侧所有 action 分支在 `PanelController.handle(action:payload:)`
- 新增能力时：**PanelController 加 case → shell.ts 的 `api` 对象暴露 → docs/plugin-api.md 补表**（三处一起改）

常用 action：`searchApps` `getIcon` `launchApp` `listPlugins` `loadPlugin` `setPluginKeyword`
`getUsage` `recordAppUsage` `recordPluginUsage` `dbGet/dbSet/dbRemove` `getLocale` `setPanelHeight`
`showNotification` `openPath` `openURL` `showInFinder` `getFileIcon` `getPath` `copyText` `getClipboardHistory` …

## 4. 应用索引（性能关键，改动前务必读完）

`AppSearcher` 分四层，**搜索路径上不允许有任何磁盘 IO**：

1. **磁盘缓存** `~/Library/Application Support/ya/app-cache.json`
   启动时同步读入 → 冷启动第一个字母就能搜到全部应用（约 104 个 / 15KB，含预计算拼音）
2. **后台扫描**：启动后在 `utility` 队列重扫一次，写回磁盘并预热全部图标
3. **目录监听**：DispatchSource 监听 `/Applications`、`/Applications/Utilities`、`/System/Applications`、`/System/Applications/Utilities`，变化后防抖 1.5s 重扫（**已删除原来的 5 分钟定时轮询**，只保留 15 分钟兜底）
4. **搜索**：纯内存过滤 + 5 级相关度排序（名称前缀 > 全拼前缀 > 名称包含 > 全拼包含 > 首字母子序列）

图标：`cachedIcon()` 同步取缓存（主线程可调用，绝不 IO）；`requestIcon()` 后台生成后主线程回调。

## 5. 插件体系

**存放位置**：内置 `App 包内 Web/plugins/`（不可删）；用户 `~/Library/Application Support/ya/plugins/`（可导入/删除，同 id 覆盖内置）。

**plugin.json**：

```json
{
  "keyword": "calc",            // 主关键字（必填，或用 keywords）
  "keywords": ["calc", "math"], // 别名（可选，主关键字自动并入）
  "icon": "🧮",                 // 图片文件名 或 emoji；没有则按首字母生成彩色图标
  "name": { "en": "Calculator", "zh": "计算器" },
  "description": { "en": "...", "zh": "..." },
  "provider": true,             // 可选：结果提供者，见下（声明后 keyword 可省）
  "features": [                 // 可选：多入口，见下
    { "cmd": "clear", "title": { "en": "Clear", "zh": "清空" }, "keywords": ["calcclr"] }
  ]
}
```

**关键字规则**：规范化为小写、去首尾空白、**不能含空格**。冲突时「内置优先 → 同级按 id 字典序」先声明者占用；被抢占的关键字不参与匹配，插件标记 `conflictWith`，管理页「冲突」列可见。用户可在插件管理页双击关键字列自定义，写入 `~/Library/Application Support/ya/keyword-overrides.json`，「重置关键字」恢复。

**多入口（features）**：`PluginIndex.parseFeatures` 把每个 `features[]` 项的关键字也放进同一张冲突表（与插件主关键字平等竞争，全被抢占则该入口不可用）。进入方式：`clipclear 参数`（入口专属关键字）或 `clip clear 参数`（主关键字 + cmd）。宿主在切换入口时先调 `onFeature(cmd, api)`，再把 `{cmd, title}` 作为 `onQuery` **第四参数**传给插件（主入口 cmd 为空串）。剪贴板插件（`~/Desktop/ya-plugin/clipboard`）的 `clear` / `files` 是现成例子。

**两种插件形态**（2026-09-26 引入）：

|  | 接管面板型（默认） | 结果提供者（`provider: true`） |
| --- | --- | --- |
| 触发 | 必须「关键字 + 空格」 | 每次搜索都问一次 `onProvide(query, api)` |
| 渲染 | 插件自己画 `container` | **宿主渲染**，插件只返回 `ProviderItem[]` |
| 关键字 | 必填 | 可选（不写就不占关键字、不参与冲突、不出现在「我的插件」） |

provider 的调度在 `shell.ts` 的 `doSearch()`：并发问所有 provider，合并进 `items` 最前面，
带三道护栏——**单次 300ms 超时**（`callBridge` 的 10s 太宽，击键级代码不能用）、**抛异常本次会话
禁用该 provider**、**单插件最多 3 条**。原生侧放行无关键字的 provider：`PluginImporter`
的关键字校验对 `provider: true` 开绿灯，`PluginIndex` 的 `listPayload` 带 `provider` 布尔、
`isEnterable` 表示「能否被关键字唤醒」，`match.ts` 的「插件」组只列 `isEnterable` 的。
现成例子：`~/Desktop/ya-plugin/smart`（智能识别，双入口 `s` / 免关键字）。

**进入插件的触发条件**（容易改坏）：
- 必须「关键字 + 空白」才进插件视图；只输入 `cal` 时插件只是搜索结果项，回车/Tab 才进入
- 已进入插件后，只要输入仍以关键字开头就保持在插件内（删到 `cal` 才退回搜索）
- 输入法组合态（候选未上屏）不切换插件

**退出插件是两级**（`resetToSearchInit()`）：
- **Esc 第一级**：插件内 / 有输入时 → 清空输入、`onExit()`、回到搜索初始页（网格），**不隐藏面板**
- **Esc 第二级**：已在初始页（输入为空）→ 才 `callBridge("hide")`
- 插件 `onKey` 先拿到 Esc，返回 true 则可拦截（自己定义 Esc 语义）；不拦截才走上面的两级逻辑

**面板再次呼出：默认回到上次的插件**（`__onPanelShown` → `resumeActivePlugin()`）。用户只是把面板收起来（切到别的应用 / 点外面 / 插件自己调 `hide()`），再呼出时**继续显示上次那个插件**，输入内容、插件状态都还在；只有**主动按 Esc 退出**过才回搜索初始页。恢复时会用当前参数再问一次 `onQuery`（收起期间外部数据可能变了，剪贴板插件最典型），但**不重设视口高度**（已在插件内，重设会把当前高度固化成新下界，见坑 38）。插件在这期间被卸载 → 回初始页。

**生命周期钩子**：`onQuery(arg, container, api)` 必填；`onProvide(query, api)` 仅 provider 插件用；`onKey(e, container, api)` 返回 true 表示已消费；`onEnter(api)` / `onExit()` 是**进入/离开插件**钩子，**不是回车键**（历史上踩过坑，见 §7）。`onExit` 只在真正退出插件时触发（Esc / 换插件 / 输入不再是它的关键字），**面板隐藏不触发**。`resetToSearchInit()` 是「重置回搜索初始页」的唯一入口：Esc 第一级和「不需要恢复插件」时的面板呼出都调它，改重置逻辑只改这一处。

**安装**：zip 导入（`ditto -xk`，防 zip-slip，原子替换，只有 main.ts 时用本机 tsc 就地编译）；网页 `yatools://install?url=<https zip>` 一键安装。

**插件样式**（`style.css`）：宿主加载插件时自动注入，宿主容器 `#pluginView` 带 `.ya-plugin-<id>`，`injectPluginCss()` 用 CSSOM 给每条选择器加这个前缀（`:root` / `body` / `html` / `#pluginView` 映射到容器自身），`@media` 递归处理，`@keyframes` 不动。这样插件写 `.card {}` 也不会污染宿主和其它插件。插件应优先用 `shell.css` 里定义的 `--ya-*` 变量而不是写死颜色。**新增/修改插件样式时不要把插件样式塞回 `shell.css`**——插件样式都在插件自己目录的 `style.css` 里。

## 6. 面板布局：列表 vs 网格

`ResultItem.grid` 决定一条结果怎么渲染，两种模式并存：

| 模式 | 用在哪 | 形态 |
| --- | --- | --- |
| 网格（`grid: true`） | 初始页的「最近使用」「我的插件」 | 一行 6 个方形卡片：40px 图标 + 两行名称，连续同类项塞进同一个 `.grid` 容器 |
| 列表（`grid: false`） | 搜索结果的「插件」「应用」分组 | 整行一项：图标 + 标题 + 副标题（关键字/描述） |

- `GRID_COLS = 6` 在 `ui.ts` 里，**必须与 `shell.css` 的 `.grid { grid-template-columns: repeat(6, 1fr) }` 保持一致**，否则行列布局会和屏幕错位
- 键盘走**行列布局表**而不是索引加减：`buildLayout()` 在渲染时给每个可选中项算出 `{row, col}`（网格卡片每行 GRID_COLS 个，分组标题独占一行，列表项占满整行），
  `moveSelection()` 按这张表找"屏幕上真正相邻的那一项"——所以 **↑↓ 能跨分组连续移动**（三组网格是打通的），
  ↑↓ 会跳过空的标题行，目标行没那么宽时落到最接近的那一列；←→ 只在**同一行内**左右挪，越界不动
- 「最近使用」= **应用和插件共用一条时间线**（`UsageHistory` 每条记录带 `ts`，按最后使用时间混排），
  最多 12 个 = 两排卡片（`RECENT_MAX = GRID_COLS * 2`）。以前是两个分组，刚用过的插件会被压在整排应用后面；
  纯结果提供者（无关键字）不占卡片位（点进去没东西可显示）
- 「我的插件」= 全部已安装插件（允许与「最近使用」重复）
- 面板高度自适应：搜索态下按内容高度调 `setPanelHeight`（200~560，带 40px 滞后防抖）
- 插件视图的高度**由宿主统一裁决，不交给插件**（见坑 38）：进入插件时先 `capturePanelViewport()`
  记下搜索态总高，`setMode('plugin')` 之后立刻 `beginPluginViewport()` 把内容视口钉在
  「刚才那份搜索结果的高度」上（剩下的是搜索栏让出来的那 52px，归插件内容区）——
  所以插件哪怕还没跑第一次 `setExpendHeight`，面板也是最终尺寸，不会先矮后高地跳一下；
  之后插件的自报高度只会在 `[下界, 560 封顶]` 之间挪，并且带 40px 滞后；超过上限就在 `#pluginView` 内滚动

## 6.1 宿主输入框

输入框是**唯一的键盘入口**（插件自己不接管焦点），所有按键都先经过它再分发给插件。

| 能力 | 实现 |
| --- | --- |
| ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z / ⇧⌘Z | `keydown` 对 `metaKey \|\| ctrlKey` 放行给 WebKit；AppKit 侧补了不显示的 Edit 菜单（见坑 18）。**注意顺序**：插件态要先让插件 `onKey` 消费 ⌘ 组合（⌘P 收藏等），没消费才放行（见坑 24） |
| 右键菜单 | WKWebView 没有自带文本菜单，宿主画 `#ctxMenu`（撤销/重做/剪切/复制/粘贴/全选）；复制/粘贴走桥接（`setClipboard` / `getClipboardText`），因为 `execCommand("paste")` 被 WebKit 禁用 |
| ← → | 既是光标移动也是结果导航：`cursorCanMove()` 判断框内还有可移动空间（有选区或光标不在两端）→ 放行移动光标，到头之后才 `moveSelection(±1, true)` 导航 |
| 插件态收起 | 进插件后搜索栏离屏（`.off`），交互交给插件；插件可用 `plugin.json` 的 `input: "visible"`、`api.setSubInput()` 或 `api.showInput()` 把它放回来（见坑 19） |

## 6.2 深浅色主题（跟随系统）

- CSS 只有**一份**：深色写在 `:root`（默认），浅色在同批变量名上 `@media (prefers-color-scheme: light)` 覆盖；
  `:root` 上带 `color-scheme`，原生滚动条跟着明暗变。
- 手动切换（设置里「外观：跟随系统 / 浅色 / 深色」）不改 CSS —— `Theme.swift` 设 `NSApp.appearance`，
  WebView 的 `prefers-color-scheme` 跟着它走，AppKit 窗口也一起换肤。改外观后发 `.yaThemeChanged`，
  面板**藏着时**重载一次 shell；正显示时交给 WebView 自己更新。
- **规则：颜色字面量只准出现在两个 `:root` 调色板块里**，其余一律 `var(--ya-*)`。
  theme.test.mjs 会对这两条各设一条断言（浅色块漏一个变量 = 浅底浅字看不见；调色板外写死 = 那块永远深色）。
  新增常驻 UI 时先加变量再引用，两块都要写。
- 插件侧：`--ya-*` 引了就自动跟随；语义色挑明暗都读得清的值（参考 plugin-api.md）。

## 7. 构建 / 运行 / 调试

```bash
cd ya
./build.sh      # tsc --outFile 编译 TS + swift build -c release（必须 --disable-sandbox，已写进脚本）
./package.sh    # 生成 dist/ya.app（图标、Info.plist、ad-hoc 签名、lsregister 使 URL scheme 生效）
./run.sh        # 独立会话常驻启动（setsid）
./stop.sh       # 停止
```

注意：`typescript` 必须 5.x（6+ 移除了 `--outFile`），tsc 与 node 路径硬编码在 `build.sh` / `PluginImporter.swift` 里。

调试环境变量（启动二进制时生效，GUI 进程 stdout 是块缓冲，打印后必须 `fflush`）：

```bash
YA_DEBUG=1              # 打印当前快捷键、应用索引来源/数量、插件关键字与冲突、后台生成图标自检
YA_IMPORT=/path/a.zip   # 启动时导入插件
YA_DELETE=<plugin-id>   # 启动时删除插件
YA_INSTALL=<url>        # 免确认走完整安装链路
```

## 8. 已踩过的坑（**别再踩**）

1. **`JSONSerialization.data` 会抛 ObjC 异常**，Swift 的 `try?` 挡不住 → SIGABRT。剪贴板等不可信字符串必须走 `SafeJSON`。
2. **`image.size = NSSize(32,32)` 不会缩小位图**，TIFF 仍保留 512px 表示，单个 base64 达 475KB（预热 200 个≈95MB）。必须重绘到新 `NSImage(size:flipped:drawingHandler:)` 才真正降采样。
3. **主线程做 `NSWorkspace.icon(forFile:)` 会卡住输入**（中文输入法下输入第二个字母明显卡）。图标一律后台生成 + 异步推送。
4. **`onEnter` 不是回车**：计算器曾把「Enter 复制」写成 `onEnter`，导致进入插件瞬间就执行并关闭面板。
5. **`ensurePluginLoaded` 命中缓存必须恢复 `activePlugin`**，否则只触发一次 onInput 时插件实例是 null，`calc 2+2` 不显示结果。
6. **`nohup` 启动的进程会被进程组杀掉**（表现为"唤不起"）。`run.sh` 用 python `Popen(start_new_session=True)` 建独立会话。（`launchctl bootstrap` 此环境失败，已弃 plist 方案）
7. **SPM 资源 bundle 没有 Info.plist**，`codesign` 会报 unsealed contents → Web 资源直接拷进 `Contents/Resources/Web`，由 `AppResources.webRoot` 定位（回退 `Bundle.module` 便于开发态）。
8. **`NSAlert.runModal()` 在 AppleEvent 处理上下文会被系统自动按掉默认按钮**（实测 1.6s 放行）→ 安装确认改用非模态窗口 + 显式回调。
9. **`WKUserContentController` 强引用 message handler** → 用 `WeakScriptMessageDelegate` 打破循环引用。
10. **枚举 `@objc`**：`enum` 不能有 `@objc` 成员，需要 selector 的类型得用 `final class`。
11. **`RegisterEventHotKey` 返回 noErr 不代表按得出来**（⌘Space 实测被系统截获）→ 需要黑名单提醒，详见 §9。
12. **面板是 `.floating` 级，会盖住设置等普通窗口** → 打开任何窗口前先发 `.yaHidePanel`。
13. **WebView 的读权限只在 `Web/` 目录内**（`loadFileURL(allowingReadAccessTo:)`），用户插件目录在
   Application Support 下，**跨目录的 `file://` 图片会加载失败**。所以插件 CSS 里的相对 `url()` 由
   `PluginLoader.inlineAssets` 换成 data URL，`api.assetUrl()` 同理（上限 512KB/文件）。
14. **插件 CSS 直接进 `<head>` 会全局生效**，插件写 `div {}` 就会污染宿主界面。
   `injectPluginCss()` 必须用 CSSOM 给选择器加 `.ya-plugin-<id>` 前缀，且 `<style>` 要带 id 便于重复注入时先移除。
15. **`bridge / types / match / ui / edit / shell` 由 `tsc --outFile` 合成一个 `shell.js`**，处于同一作用域（全局脚本）：
    **任何文件都不能有同名的顶层 `const`/`let`**（连测试 harness 里的
    driver 脚本也会撞 —— 曾用 `const mode` 把整个 shell.js 干挂）。改 build.sh / test.sh 的文件列表前先看这条；
    文件顺序 = 拼接顺序，`match.ts` 必须在 `ui.ts` 之后、`shell.ts` 之前。
    （两处列表必须一致：build.sh 出生产产物，test.sh 出单测加载的那份，顺序不一致就会验了个寂寞。）
16. **智能识别（原「万能输入框」，2026-09-26 已插件化到 `~/Desktop/ya-plugin/smart`）的识别必须保守**：
   纯数字会被当成进制/颜色/时间戳，所以颜色要求 `#` 前缀或含 a-f 字母、
   十进制进制转换限 6 位以内、且已有其它识别结果时不再给进制转换，否则搜手机号/验证码时会刷屏。
   识别器现在在插件的 `src/recognize.ts`（纯函数、单测 35 条），宿主已不含这份逻辑。
17. **剪贴板历史不再是 `string[]`**：`getClipboardHistory` 返回结构化条目（含 `id`/`kind`/`pinned`/`hasImage`），
   插件写回剪贴板要用 `restoreClipboardItem`（而不是 `setClipboard` 塞文本，文件/图片条目会退化成路径字符串）。
18. **accessory app（无菜单栏）里 WKWebView 的 ⌘C/⌘V 完全没反应**：AppKit 拿 key equivalent 去 `mainMenu`
   找匹配 item 再沿响应链派发，没有菜单项就匹配不到。`AppDelegate.buildEditMenu()` 补了一个不显示的
   Edit 菜单（item 的 `target` 留 nil，真正干活的是响应链上的 WebView），`EditMenuActions` 只为凑 selector。
19. **弹窗必须走 `Alert.swift`**：accessory（无 Dock 图标）应用没有窗口时 `runModal()` 可能立刻返回
   （弹窗一闪就没），展示期间要临时切成 `.regular`；另外按钮文案、"好/OK"默认值也统一在里面。
   直接 `NSAlert()` + `runModal()` = 少写了 activationPolicy 切换，是这个 bug 反复出现的根源。
20. **序列化落盘一律用 `SafeJSON`**：`JSONSerialization.data` 遇到剪贴板文本、用户关键字里的特殊字符会抛
   ObjC 异常（坑 1），剪贴板历史 / 应用索引缓存 / 关键字覆盖表都已切到 `SafeJSON.data()`。
21. **`NativeServices.fileIcon` 曾漏用 `IconUtil`**：直接 `image.size = 32` 是假缩放（坑 2），
   一个文件图标的 base64 可达数百 KB。取图标一律走 `IconUtil.pngBase64(_:size:)`。
22. **插件态收起输入框不能用 `display:none`**：元素一隐藏焦点就丢，键盘输入进不来，`onQuery`/`onKey` 会全部失灵。
   `#searchbar.off` 走的是「移到屏幕外但保留 1×1 尺寸 + 仍可聚焦」，并在切换后抢回焦点。
   因此插件必须**自己回显**用户输入（剪贴板显示 `🔍 过滤词`；原内置计算器显示 `2+2 =`）。
23. **搜索态回车选中插件必须 `e.preventDefault()`**：`it.action()` 会同步把焦点切进插件自己的编辑区
   （插件在 `onQuery` 里 focus 自己的 textarea 是常态），这次回车的**默认动作**于是落在插件输入框上 →
   一进插件就多一个换行（Tab 分支早就有 `preventDefault`，Enter 漏了）。
   插件侧的兜底：首次挂载用 `setTimeout(focusText, 0)` 延后一拍抢焦点（宏任务晚于本次默认动作）。
24. **插件 `onKey` 必须在「⌘/⌃ 放行」之前**：给输入框补编辑快捷键时，曾在 `keydown` 顶部
   `if (metaKey || ctrlKey) return;` —— 这会把剪贴板插件的 ⌘P 收藏 / ⌘⌫ 删除在到达 `onKey`
   之前就吞掉。现在插件态先让 `onKey` 消费（含 ⌘ 组合），没消费才轮到放行（见 §7 的 keydown 顺序）。
25. **面板拖拽的 `mousedown` 里不能 `preventDefault()`**：加了整块面板可拖之后，曾为了「拖动不带走
   选区」在这里拦默认行为，结果 WebKit 会把随后的 `click` 一起吞掉 —— 插件自己画的交互全废
   （剪贴板「点一行就复制」点了没反应；搜索结果项因为在排除名单里才没事）。
   现在只记录起点，真正达到拖动阈值时才 `getSelection()?.removeAllRanges()` 清选区；
   另外没拖动的这次 `mouseup` 要把焦点还给宿主输入框（preventDefault 顺带丢焦点 → 打字全丢）。
26. **`setExpendHeight` 传的是「插件内容区高度」，宿主负责补外壳**：`setPanelHeight` 设置的是面板总高，
   而面板里还有搜索栏（未收起时）和底栏。以前直接把插件给的值当总高，每个插件都得自己猜底栏多高，
   少算那 30 多 px，内容就被挤出一条滚动条（URL 编解码插件就是这么翻的车）。
   现在 `shell.ts` 的 `panelChromeHeight()` 加上「拖拽条 + 搜索栏（流内时）+ 底栏 + 16」，与搜索态
   `autoHeight()` 同口径（**新增任何常驻条都要两边一起加**，漏一个就矮一截、挤出滚动条）。
   插件自己只要量 DOM 再加 `#pluginView` 的 28px 内边距即可。
27. **`features[].keywords` 必须以插件主关键字开头**：宿主先用 `matchPlugins(q)` 挑出命中的插件，只在这个
   集合里找 features（`matchFeatures`）。query 比主关键字更长时插件自己就匹配不上（≥3 字的子串兜底也
   不适用），入口永远出不来。所以写法是 `clip` → `clipclear`，`urlc` → `urlcenc`；
   `ue` 这种与主关键字无关的短词只在「`ue 内容`」带参直通时可用，只敲 `ue` 什么都搜不到。
28. **拖面板只能用鼠标屏幕坐标 + 原生锚点，绝不能累加 `clientX/clientY` 增量**：
   `clientX` 是**视口**坐标，窗口往右挪 10px，鼠标不动 `clientX` 也会减 10 —— 于是下一次算出的增量里
   混进了「窗口刚才自己移动了多少」，形成正反馈：+10 / -10 / +10 / -10 … 面板原地抖。
   现在 `ui.ts` 只上报 `e.screenX/screenY`（屏幕坐标不受窗口移动影响），`PanelController` 在
   `beginPanelDrag` 时记下「窗口原点 + 鼠标屏幕位置」作锚点，`movePanel` 用锚点算绝对位置，
   `endPanelDrag` 才写 `AppSettings.panelOrigin`。
   另外两个卡顿源一并处理：每个 `mousemove` 都等一次桥接回包（`evaluateJavaScript` 回灌主线程）会让
   窗口移动一卡一卡 —— 拖拽改走 `postBridge()`（`id: 0`，原生不回包），并用 `requestAnimationFrame`
   合并成一帧最多上报一次；落盘也从「每次移动都写 UserDefaults」改成松手才写一次。
29. **「我的插件」必须列全部插件，且使用历史要清僵尸 id**：初始页 `showUsage()` 原本把「最近插件」里
   出现过的从「我的插件」里剔除，用户数着数着就以为「导入的插件少了一个」（3 个插件 → 显示 2+1）。
   两条一起看才是完整现象：`UsageHistory` 里堆着已不存在的 id（删掉的 `calculator`、改名前的 `url`、
   测试残留 `hello`），能匹配上的只剩一个，于是「最近插件」永远只有那一个。
   现在「我的插件」列全部（允许与「最近使用」重复，后者是一整条时间线、最多 12 个），`getUsage` 前先
   `usageHistory.prunePlugins(keeping:)` 把不存在的 id 清掉并落盘；另外**进入插件即记录使用**
   （以前要求「带参数或走 feature 入口」才记，敲 `qr` 回车进去用一通也不算）。
30. **推给 JS 的字符串别再手包一层引号**：`SafeJSON.string()` 返回的结果**已经自带两侧引号**，
   再写成 `evaluateJavaScript("__setHotKey(\"\(text)\")")` 会推出 `"⌥ Space"`（带字面引号），
   底栏提示就多了一对引号。正确写法是 `evaluateJavaScript("__setHotKey(\(text))")`。
31. **判断「用户填的关键字是否和插件自带一致」必须用 `PluginIndex.manifestKeywords(id:)`**：
   `Entry.declaredKeywords` 在有用户覆盖时返回的是**覆盖值**，拿它比对会导致「用户把自定义关键字
   原样再保存一次」被判成「与插件自带一致」→ 覆盖被清掉 → 关键字悄悄退回 plugin.json 的值。
   `manifestKeywords()` 直接读 manifest、忽略覆盖表。
32. **`PluginStorage` 注入目录时必须自己把目录建出来**：生产路径 `AppPaths.storage` 会 ensure，
   但注入一个新目录时不会；`save()` 里的 `try?` 会把写入失败静默吞掉，表现是「存了读不出来」。
   已在 `init(dir:)` 里补 `createDirectory`。
33. **白屏不会有任何报错**：面板是一个裸 `WKWebView`，`shell.js` 出语法错误（坑 15 那类顶层重名）
   时页面全白，用户只会说"点了没反应"。所以前端在脚本末尾置 `window.__yaScriptLoaded`，
   原生 `didFinish` 后延迟 2.5s 查这个标记，没置位就重载（最多 3 次），仍失败才弹提示。
   另一个方向：`webViewWebContentProcessDidTerminate`（网页进程被系统回收）没有任何 JS 回调，
   也必须靠 `WKNavigationDelegate` 兜。
34. **`pkill` / `kill`（SIGTERM）不会走 `applicationWillTerminate`**：`./stop.sh` 用的正是 pkill，
   不处理的话每次脚本重启都会被判成"上次崩溃了"，诊断报告里那条「上次退出：异常」就是噪音。
   `AppDelegate.installTerminationHandler()` 用 `signal(SIGTERM, SIG_IGN)` + `DispatchSource`
   把 SIGTERM 转成一次正常退出（`DispatchSource` 必须自己持有引用，否则收不到）。
   只有 SIGKILL / 真崩溃才会留下 `cleanExit: false`。
35. **写日志别用 `FileHandle`**：macOS 10.15.4+ 把它的 `write` / `close` 改成了 throwing 版本，
   写 `try?` 在旧签名上会报 "no calls to throwing functions" 警告（构建要求零警告）。
   `Log.swift` 直接用 `Darwin.open` / `write` / `fsync`，顺带也避开了 SDK 差异。
36. **provider 是「每次击键都跑」的用户代码，必须有护栏**：`onProvide` 若允许慢，一个写烂的插件
   就能把输入框卡死；`callBridge` 的 10s 超时在这里毫无意义。宿主侧三道：单次 300ms 超时
   （`Promise.race` 超时后丢弃结果）→ **本次会话禁用该 provider**；抛异常同样禁用；
   单插件最多 3 条。禁用只到本次会话，重启面板恢复（设成永久禁用会让用户永远不知道为什么没了）。
37. **前端单测里别用固定 `sleep` 等异步渲染**：插件首次加载要走一次真实桥接往返、
   provider 又可能是异步 `Promise`，固定 60ms 在开发机上够、在 CI 上就随机失败。
   `Tests/web/harness.mjs` 的 `h.waitFor(fn, { label })` 会轮询到条件成立为止，
   失败时 `label` 直接写进断言信息（"等 provider 条目出现 超时"），比 `sleep` 后断言空数组好查得多。
38. **插件面板高度必须由宿主统一裁决，不能让插件自己封顶**：每个插件各写一套
   （qrcode `Math.min(900, …)`、smart `MAX_HEIGHT`、urlc 又一个常量），结果是
   ① 从搜索结果敲关键字进插件，面板先落到宿主兜底高度、再被插件改成它想要的值 —— 肉眼可见地跳一下；
   ② 在插件里每敲一个字，`setExpendHeight` 的新值都会让窗口换一档尺寸 —— 一直在闪。
   现在统一口径（见 `ui.ts`）：进入插件时**在 `setMode('plugin') 之前**用 `capturePanelViewport()`
   记下搜索态面板总高（之后搜索栏离屏、结果区隐藏，两个都测不到了），切换完立刻 `beginPluginViewport()`
   把内容视口钉在「刚才那份搜索结果的高度」上（搜索栏让出的 52px 正好归插件内容区，总高不变），
   所以插件还没跑第一次 `setExpendHeight` 时面板已经是最终尺寸；插件后续的自报高度只会被夹进
   `[下界, 560 封顶 − 外壳]`，且带 40px 滞后不上报小幅摇摆，超过上限的内容由 `#pluginView` 自己滚动
   （CSS 里 `overflow-y: auto`，JS 把 `min-height` / `max-height` 打到同一个值）。
   退出插件必须 `resetPluginViewport()` 清掉三个人：**inline 尺寸补丁**、`pluginViewportHeight`、
   以及 `lastPanelHeight` —— 最后这个不清，搜索态 `autoHeight()` 会被插件留下的高度卡在滞后区里缩不回来。

## 9. 全局快捷键（可配置）

- 默认 `⌥Space`。模型是 `HotKey(keyCode: UInt32, modifiers: UInt32)`（Carbon 虚拟键码 + 修饰键掩码），
  持久化到 `ya.hotkey.keyCode` / `ya.hotkey.modifiers`，读取入口 `AppSettings.shared.hotKey`
- 修改路径：设置窗口里的 `HotKeyRecorder`（点一下进入录制态，按下组合键即保存，Esc 取消）
  → `AppSettings.shared.hotKey = …` → 发 `.yaHotKeyChanged` → `AppDelegate.registerHotKey()` 重新注册
  → 发 `.yaHotKeyRegistered` → 状态栏 tooltip 与前端 `window.__setHotKey()` 同步刷新文案
- **要求至少一个修饰键**（⌘/⌥/⌃/⇧）或 F1–F20，否则会吞掉正常输入
- **`RegisterEventHotKey` 返回 noErr ≠ 按得出来**：实测 ⌘Space 注册成功但被聚焦搜索截获，
  表现为"改了没反应"。所以保留了一份 `maybeSystemReserved` 黑名单，命中时弹警告但**不回滚**（尊重用户选择）；
  真正的注册失败才会回滚到默认并提示

**打开窗口前先收面板**：面板是 `.floating` 级，会盖住普通窗口。状态栏菜单打开设置/插件管理/关于、
以及设置窗口里的「插件管理…」都会先发 `.yaHidePanel`，由 `PanelController` 收起面板。

## 10. 验证方式（重要：此环境不能驱动 GUI）

这台机器**没有辅助功能权限**，`osascript` 模拟按键会报 `-10004`，无法用脚本操作面板。
所以**一切能靠单测覆盖的都走单测**，不再手写临时验证脚本（历史上那些 `/tmp/yaweb*` 无头页面
已全部废弃，能力并入 `Tests/`）。

### 一键跑全部

```bash
./test.sh          # 原生（XCTest）+ 前端（node:test）
./test.sh web      # 只跑前端（会先 tsc 编译 shell.js，前端单测加载的就是这份真实产物）
./test.sh swift    # 只跑原生
```

改完代码**必须先 `./test.sh` 全绿**，再打包重启。

### 前端单测（`Tests/web/`）

`node:test` + `jsdom` 直接加载**真实的** `Sources/ya/Web/index.html` 与构建产物 `shell.js`，
只把唯一的外部依赖（原生桥接）换成桩。两个关键技巧：

1. 桥接桩必须在 `beforeParse` 里装 —— 要早于 `shell.js` 执行，否则 `boot()` 里的 `callBridge`
   会撞上 `undefined`。
2. `shell.js` 是 `tsc --outFile` 拼出来的**普通脚本**，顶层 `let/const`（`items` / `mode` /
   `manifests` …）进的是全局词法环境而不是 `window`。用 `window.eval("items")` 能读到、
   `window.eval("items = X")` 能写（间接 eval 跑在全局作用域，能看到全局词法声明）。
   取数组/对象时统一走 `h.json(...)`（JSON 往返一次）—— jsdom 的 `Array` 原型属于另一个
   realm，直接 `deepEqual` 会因为原型不同而误判。

覆盖：搜索匹配与拼音、初始页分组（坑 29）、面板高度口径（坑 26）、面板拖拽（坑 25 / 28）、
按键顺序（坑 23 / 24）、CSS 作用域、二维布局、插件调度与插件 API、provider 调度与三道护栏（坑 36）。

> 插件自己的单测住在插件工程里（`~/Desktop/ya-plugin/<id>/test/`），`pnpm test` 跑，
> 不进宿主 `Tests/web/` —— 宿主只验机制，识别/业务逻辑由插件自己验。

### 原生单测（`Tests/yaTests/`）

`@testable import yaCore`。为了让单测不碰真实用户数据，几个入口都做了注入：

| 注入点 | 用途 |
| --- | --- |
| `AppPaths.rootOverride` | plugins / storage / clipboard-images / 根目录下的 json 全部改指临时目录 |
| `AppResources.webRootOverride` | 内置插件目录改指临时目录 |
| `PluginStorage(dir:)` | 插件 KV 库指向临时目录 |
| `UsageHistory(defaults:)` | 用独立的 `UserDefaults(suiteName:)`，绝不写 `.standard` |

基类 `YaTestCase` 负责建/删临时目录并复位注入，`AppSettingsTests` 会快照并还原它改动的
`UserDefaults.standard` 键（这个文件读写的是真机设置，必须还原）。

### 仍然只能手工验的部分

真机交互（⌘V 粘贴、拖面板手感、Dock 闪现）与 GUI 窗口布局。改完按 §7 打包重启后手动看一眼。

## 11. 数据存放位置

| 内容 | 路径 |
| --- | --- |
| 用户插件 | `~/Library/Application Support/ya/plugins/<id>/` |
| 插件 KV 存储 | `~/Library/Application Support/ya/storage/` |
| 剪贴板历史 | `~/Library/Application Support/ya/clipboard.json` + `clipboard-images/<id>.png` |
| 关键字覆盖表 | `~/Library/Application Support/ya/keyword-overrides.json` |
| 应用索引缓存 | `~/Library/Application Support/ya/app-cache.json` |
| 设置 / 使用历史 | `UserDefaults`（key 前缀 `ya.`，从旧 `quicklauncher.` 自动迁移） |
| 快捷键 | `UserDefaults`：`ya.hotkey.keyCode` + `ya.hotkey.modifiers`（两个键齐全才生效） |
| 运行日志 | `~/Library/Application Support/ya/ya.log`（超过 512KB 只留最近缓冲内容） |
| 上次启动标记 | `~/Library/Application Support/ya/last-launch.json`（`cleanExit` 为 false 即上次非正常退出） |

## 12. 诊断与反馈（内测期必备）

用户报障时最缺的是现场，这里把三件事做成一键可得：

| 入口 | 做什么 |
| --- | --- |
| 菜单栏「导出诊断信息…」/ 设置窗口同名按钮 | 存出一个 `ya-diagnostics-<时间>.txt`：版本、系统、架构、快捷键、上次退出是否异常、数据目录与各文件大小、插件列表（含版本/关键字/入口/冲突）、关键字冲突、最近 500 行日志 |
| 菜单栏「打开数据目录」 | 直接在 Finder 打开 `~/Library/Application Support/ya` |
| 设置窗口底部「上次退出：正常/异常」 | 一眼区分「崩溃过」还是「设置被改了」 |

- 日志**同时**进内存环形缓冲和 `ya.log`：进程崩溃时磁盘常常来不及 flush，内存里的最后几百行才是现场。
- 只有 `NSException` 能被 `NSSetUncaughtExceptionHandler` 接住；Swift 的强制解包 / `fatalError`
  走的是信号，在 signal handler 里写日志容易死锁在锁上，**这里不接信号**，这类崩溃靠
  「上次退出：异常」发现（见坑 34）。
- 白屏不弹错：见坑 33，靠 `__yaScriptLoaded` + `WKNavigationDelegate` 自愈。

## 13. Git 与提交约定

- 仓库：`origin = https://github.com/kongben/ya.git`，**默认分支 `master`**。
- **commit message 一律用英文**（历史要能被任何人直接读懂，也避免中英混排）。
  格式用 Conventional Commits 的简版：

  ```
  <type>: <imperative summary under 72 chars>

  - optional bullet: why, not what
  ```

  `type` 取 `feat` / `fix` / `refactor` / `perf` / `test` / `docs` / `chore` / `build`；
  示例：`fix: keep plugin viewport floor after exit`、`chore: ignore build output`。
- 一次提交只做一件事：改代码和跑测试分开写，方便 revert。
- 提交前跑 `./test.sh`（Swift + Web 全量），红着不许提交。
- `.gitignore` 已经挡掉 `.build/`、`dist/`、`Sources/ya/Web/shell.js`、
  `Tests/web/node_modules/`、`.DS_Store`；**别用 `git add -f` 把这些塞进来**。
  注意 `shell.js` 是 `tsc --outFile` 的产物，改行为要改 `Sources/ya/Web/*.ts`。
