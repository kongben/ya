# ya 插件 API 文档

本文档描述 ya 为插件提供的原生能力（JS API）。设计参考 [uTools 插件开发文档](https://www.u-tools.cn/docs/developer/) 中「系统 / 窗口 / 复制 / 本地数据库」四类 API，并结合本项目（Swift 原生 + WKWebView）的实现做了适配。

## 一、插件结构

一个插件是一个目录，包含三个文件：

```
myplugin/
├── plugin.json   # 插件声明（名称、关键字等）
├── main.ts       # 插件逻辑（编译后为 main.js）
└── style.css     # 可选，插件样式
```

插件有两个存放位置：

| 位置 | 路径 | 说明 |
| --- | --- | --- |
| 内置 | App 包内 `Web/plugins/` | 随应用打包，不可删除（当前为空：宿主已不内置插件，通道保留） |
| 用户 | `~/Library/Application Support/ya/plugins/` | 可导入 / 删除，同名覆盖内置 |

`plugin.json` 示例（name / description 支持多语言）：

```json
{
  "keyword": "calc",
  "keywords": ["calc", "math"],
  "version": "1.2.0",
  "minHostVersion": "0.1.0",
  "updateUrl": "https://example.com/calc/update.json",
  "icon": "🧮",
  "name": { "en": "Calculator", "zh": "计算器" },
  "description": { "en": "Evaluate an expression", "zh": "输入表达式计算" }
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `keyword` | ✅ | 主关键字，进入插件时使用 |
| `keywords` |  | 关键字别名数组，主关键字会自动并入；多个关键字都能触发同一个插件 |
| `icon` |  | 插件图标：①图片文件名（相对插件目录，如 `icon.png`）②emoji / 短文本（如 `🧮`）。两者都没有时，宿主按关键字首字母生成彩色字母图标 |
| `name` / `description` |  | 字符串或 `{ "en": ..., "zh": ... }`，跟随系统语言显示 |
| `version` |  | 版本号，建议 `1.2.0` 形式。导入时会与已安装版本比对，管理页「版本」列显示（未声明显示 `—`） |
| `minHostVersion` |  | 插件**依赖的最低 ya 版本**。没写按 `0.1.0` 算；写了但当前 ya 更低，导入会被直接拒绝并提示升级（详见「依赖的宿主版本」） |
| `updateUrl` |  | 可选。指向一个 JSON 用于「检查更新」，见下方「版本与更新」 |
| `id` |  | 插件标识，默认用目录名 |
| `features` |  | 可选。**多入口**：一个插件对外提供多个功能，见下方「多入口插件」 |
| `provider` |  | 可选。`true` = **结果提供者**：免关键字，把搜索原文交给 `onProvide`，结果并进宿主主列表。见下方「结果提供者插件」 |
| `input` |  | 可选。`"visible"` = 进入插件后**保留**宿主输入框；不写（默认）= 收起输入框，交互由插件自己实现。见下方「输入框的显示与隐藏」 |

关键字会被规范化：去首尾空白、转小写、**不能包含空格**（否则无法与参数分隔）。

### 输入框的显示与隐藏

进入插件后宿主输入框默认**收起**（搜索栏离屏），面板只留插件视图——交互交给插件自己实现。
收起时键盘输入仍然会送到插件（`onQuery` / `onKey` 照常触发），只是看不见输入框，
所以插件需要**自己回显**用户输入（剪贴板插件会显示 `🔍 过滤词`）。

插件确实用得到输入框时，有三种方式把它放出来：

| 方式 | 用法 | 场景 |
| --- | --- | --- |
| `plugin.json` 声明 | `"input": "visible"` | 插件全程靠输入工作（如二维码：看不到输入就没法改内容） |
| `api.setSubInput(handler)` | 见窗口类 API | 插件接管输入框收参数（调用即自动显示） |
| `api.showInput()` / `api.hideInput()` | 运行时切换 | 某些入口需要输入、某些不需要 |

输入框支持标准编辑：⌘C / ⌘V / ⌘X / ⌘A / ⌘Z / ⇧⌘Z 快捷键，以及右键菜单（撤销 / 重做 / 剪切 / 复制 / 粘贴 / 全选）。

### 鼠标交互

插件视图里的鼠标事件是**原生派发**的：直接用 `onclick` 就行（剪贴板插件就是点行即复制），
不要为了让一定好使而改成在 `mousedown` 里做事——那会让「按下就触发」，语义不对。

几点约定：

- 面板整块可以拖动改位置，但**落在输入框 / 按钮 / 链接 / 结果项上的按下不会触发拖动**，
  这些元素照常点击、照常选中文本；超过 4px 才算拖动，拖完那一次 `click` 会被吃掉（避免误触发）。
- 一次「没拖动的点击」结束后，宿主会把焦点还给自己的输入框；如果插件内有该聚焦的元素
  （textarea 等），宿主不会抢。
← → 在输入框里还有可移动空间时移动光标，到头之后才切换结果选中项。

### 多入口插件（features）

一个插件不止一个动作时（比如剪贴板既要浏览、也要能直接清空），不必拆成多个插件，
在 `plugin.json` 里声明 `features`：

```json
{
  "keyword": "clip",
  "features": [
    { "cmd": "clear", "title": { "en": "Clear history", "zh": "清空历史" }, "keywords": ["clipclear"] },
    { "cmd": "files", "title": { "en": "Files only", "zh": "只看文件" } }
  ]
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `cmd` | ✅ | 入口标识，进入插件时传给 `onQuery` 的第四参数；小写无空格 |
| `title` |  | 显示名（字符串或 `{en,zh}`），缺省显示 `cmd` |
| `keywords` |  | 该入口专属关键字；缺省直接用 `cmd`。**参与全局冲突检测**（和插件主关键字平等竞争），全部被抢占时该入口不可用 |

三种进入方式：

| 输入 | 效果 |
| --- | --- |
| `clear 参数` | feature 专属关键字直接进入该入口 |
| `clip clear 参数` | 插件主关键字 + `cmd`，参数部分交给该入口 |
| `clip 参数` | 主入口（第四参数 `feature.cmd` 为空串） |

搜索时 feature 也会作为结果项出现（标题为「插件名 · 入口名」），最多补 3 条。

插件侧接收入口上下文：

```ts
__registerPlugin({
  onFeature(feature, api) { /* 切换入口时触发一次，cmd 为空串=主入口 */ },
  onQuery(arg, container, api, feature) {
    if (feature.cmd === "clear") { /* 清空视图 */ }
  },
});
```

老插件不写第四参数也完全正常向后兼容；只在切换入口时会多触发一次 `onFeature`。

### 结果提供者插件（provider）

默认形态的插件是**接管面板型**：关键字 + 空格之后，插件独占 `pluginView`，自己渲染 DOM。
而有一类功能不适合接管面板——用户只是随手粘了一串内容，希望它**在主列表里顺手出现一条结果**：
识别 JSON / 时间戳 / Base64 / 颜色、搜索文件、调用文本片段。这类要做成**结果提供者**。

在 `plugin.json` 里声明 `"provider": true`，并实现 `onProvide`：

```json
{
  "id": "smart",
  "keyword": "s",
  "keywords": ["s", "smart"],
  "provider": true,
  "name": { "en": "Instant Recognizer", "zh": "智能识别" }
}
```

```ts
__registerPlugin({
  onQuery(arg, container, api) { /* 显式关键字进入时的完整面板 */ },
  onProvide(query, api) {
    // query 是用户在搜索框里的**全部原文**（未剥离关键字）
    return [{ title: "2024-01-01", subtitle: "时间戳转日期", copy: "2024-01-01" }];
  },
});
```

与接管面板型的关键差别：

|  | 接管面板型（默认） | 结果提供者（`provider: true`） |
| --- | --- | --- |
| 触发 | 必须「关键字 + 空格」 | 每次搜索都问一次（可同时保留关键字做显式入口） |
| 渲染 | 插件自己画 DOM | **宿主渲染**，插件只返回数据 |
| 键盘导航 | 插件自己处理 | 宿主管（↑↓ / 回车 / Tab） |
| 关键字 | 必填 | 可选（不写就不占关键字） |
| 出现在「我的插件」组 | ✅ | 只有带关键字时才出现 |

`onProvide` 的返回条目（`ProviderItem`）：

| 字段 | 说明 |
| --- | --- |
| `title` | 主标题（必填，超长会被单行截断） |
| `subtitle` | 副标题 |
| `copy` | 回车要复制的文本 |
| `openURL` | 回车要打开的链接（给了会与 `copy` 一起执行） |
| `swatch` | 左侧小色块的 CSS 颜色值（颜色识别用） |
| `action` | 完全自定义动作；给了它就忽略 `copy` / `openURL`，且宿主**不会**自动收起面板 |

返回值可以同步，也可以返回 `Promise`。

> ⚠️ **护栏（务必理解）**：`onProvide` 是**每次击键都会跑**的用户代码，宿主加了三道限制：
> ① 单次超过 **300ms** 直接丢弃结果并**本次会话停用该 provider**；
> ② 抛异常同样本次会话停用；
> ③ 单插件最多 **3 条**结果。
> 所以 `onProvide` 里不要做网络请求、不要读大文件、不要有死循环，且必须自己 `try/catch` 兜住异常。
> 停用只影响本次会话，重启面板即恢复。

适合做成 provider 的功能：文件搜索、Snippets、Quicklinks、系统命令、以及本项目的**智能识别**插件。

### 插件样式（style.css）

插件目录下的 `style.css` 会在插件首次被加载时由宿主自动注入，**不需要也不能自己写 `<link>`**。

```
myplugin/
├── plugin.json
├── main.ts / main.js
├── style.css     ← 可选，自动注入
└── dot.png       ← 可选，插件自带资源
```

**作用域**：宿主会给插件容器 `#pluginView` 加上 `.ya-plugin-<插件id>` class，并把 CSS 里每条选择器都加上这个前缀，所以插件样式**只落在自己的视图里**，不会污染宿主界面和其它插件：

| 你写的 | 实际生效为 |
| --- | --- |
| `.card { ... }` | `.ya-plugin-myid .card { ... }` |
| `.a, .b { ... }` | `.ya-plugin-myid .a, .ya-plugin-myid .b { ... }` |
| `.a::before { ... }` | `.ya-plugin-myid .a::before { ... }` |
| `:root` / `body` / `html` / `#pluginView` | `.ya-plugin-myid`（容器自身，可在这里定义 CSS 变量） |

`@media` / `@supports` 里的规则同样会被改写，`@keyframes` / `@font-face` 保持原样（动画名是全局的，建议加前缀避免撞名）。

**主题变量**：宿主现在**跟随系统深浅色**（设置里也可手动指定浅色/深色）。写死颜色必然有一边看不见，
直接用宿主提供的变量 —— 深浅两套配色宿主都已备好，插件里 `var()` 一引就自动跟随主题切换：

| 变量 | 含义 | 变量 | 含义 |
| --- | --- | --- | --- |
| `--ya-bg` | 面板背景 | `--ya-accent` | 强调色（蓝） |
| `--ya-fg` | 主文字 | `--ya-sel` | 选中行背景 |
| `--ya-fg-strong` | 强文字 | `--ya-hover` | 悬停 / 占位背景 |
| `--ya-sub` | 次要文字 | `--ya-border` | 分隔线 |
| `--ya-muted` | 更弱的提示 | `--ya-radius` | 圆角（8px） |

语义色（成功 / 警告 / 失败）宿主没有变量，自己挑时要**明暗两套都读得清**（如 `#d98a1f` 琥珀、
`#e0483f` 红），必要时可在自己的 CSS 里写 `@media (prefers-color-scheme: light)` 分开给值。

**自带资源**：插件目录不在 WebView 的读权限内（宿主只开放了 `Web/` 目录），**跨目录的 `file://` 图片会加载失败**。因此 CSS 里的相对 `url()` 会被宿主自动换成 data URL：

```css
/* 可以这么写：宿主注入时会把 dot.png 内联成 data URL */
.badge { background-image: url("dot.png"); }
```

支持 png / jpg / gif / webp / svg / ico / 字体文件，单个文件上限 512KB（超了就不内联，图片会裂）。JS 里想拿资源用 `api.assetUrl("dot.png")`，返回 data URL：

```js
const url = await api.assetUrl("dot.png"); // "data:image/png;base64,..."
```

### 版本与更新

版本号只比较数字段（`1.2` 与 `1.2.0` 相等；`v` 前缀、`-beta` / `+build` 后缀会被忽略），
未声明版本时按「无版本」处理。

**导入时会告诉你版本发生了什么**（插件管理页底部状态栏、网页一键安装完成后的弹窗）：

| 情况 | 提示 |
| --- | --- |
| 首次安装 | 已安装插件：`xxx`（1.2.0） |
| 版本变大 | 已更新插件：`xxx` 1.0.0 → 1.2.0 |
| 版本变小 | ⚠️ 已降级插件：`xxx` 1.2.0 → 1.0.0（装的是旧版本） |
| 版本相同 | 已覆盖安装：`xxx`（版本未变） |

**检查更新**（需要插件声明 `updateUrl`）：插件管理页选中插件后点「检查更新」，宿主 GET 该地址，
期望返回：

```json
{ "version": "1.3.0", "url": "https://example.com/calc-1.3.0.zip" }
```

`url` 可省略（只公告版本、不自动下载）。远端版本比本地新时弹窗确认后自动下载安装。

**网页一键安装时也能跳过无谓下载**：链接带上 `id` 与 `version` 两个参数，
若本地已装且版本不低于它，直接提示「已是最新版」，不再下载：

```
yatools://install?url=https%3A%2F%2Fexample.com%2Fcalc.zip&id=calc&version=1.3.0
```

### 依赖的宿主版本（minHostVersion）

插件用到某个版本才有的宿主能力（新的 bridge 接口、新的 API）时，在 `plugin.json` 里声明
`minHostVersion`，宿主导入时会检查：

```json
{ "id": "dev-url", "keyword": "dev-url", "minHostVersion": "0.2.0" }
```

| 情况 | 结果 |
| --- | --- |
| 没写 `minHostVersion` | 按 `0.1.0` 算（只用到最初那批能力，任何正式版都装得上） |
| 写的版本 ≤ 当前 ya | 正常导入 |
| 写的版本 > 当前 ya | **拒绝导入**，提示「插件「x」需要 ya A 或更高版本，当前是 B，请先升级 ya」，并且不会留下半个插件目录 |

版本比较规则与插件版本一致（只比数字段，`1.2` == `1.2.0`）。

这条检查覆盖了所有导入入口：插件管理页「导入压缩包」、网页一键安装（`yatools://install`）、
插件「检查更新」后的自动下载安装。

已经装上但 ya 版本不够的插件（比如手动拷进插件目录、或 ya 被降级），插件管理页会在
「版本」列标 ⚠️，底部状态栏给出数量，悬停该行可以看到具体需要哪个版本。

### 关键字冲突

多个插件声明了同一个关键字时，按以下优先级决定归属：

1. 内置插件优先于用户插件
2. 同级别按插件 id 字典序，先声明者占用

被抢占的关键字**不再参与搜索匹配**，插件在列表里通过 `conflictWith` 标记抢占者，插件管理页的「冲突」列会显示出来，宿主搜索结果里该插件的副标题会提示「关键字已被其他插件占用」。插件本身仍可通过名称搜到并使用。

### 用户自定义关键字

插件管理页双击「关键字」列即可改写（多个用逗号分隔，如 `calc, math`）。自定义结果写入
`~/Library/Application Support/ya/keyword-overrides.json`，**完全覆盖** `plugin.json` 里的声明。
点「重置关键字」可恢复为插件自带的关键字。

---

## 一·一、插件如何被搜索到

搜索框里插件和应用是一起出现的，分「插件 / 应用」两组：

- 输入 `cal` → 插件组出现「计算器」，回车（或 Tab）进入插件，输入框自动变成 `calc `
- 输入 `calc 2+2` → 直接进入插件视图，参数 `2+2` 传给 `onQuery`（输入框收起，由插件回显输入）
- 已进入插件后，只要输入仍以关键字开头就保持在插件内（删到 `cal` 才退回搜索）
- 插件匹配顺序：关键字精确 > 关键字前缀 > 名称前缀 > 关键字包含 > 名称包含 > 名称全拼 > 拼音首字母模糊
- 声明了 `"provider": true` 的插件**不需要关键字**：它的结果直接并进搜索结果（分组标题「智能识别」），
  排在应用/插件组之前；它同时可以保留关键字做显式入口（见「结果提供者插件」）

用中文输入法时，候选未上屏（组合态）不会触发插件切换，避免误进插件。

## 一·二、安装与管理插件

菜单栏图标 → **插件管理…**（设置窗口里也有入口）：

- **导入压缩包…**：选择 `.zip`，包内需含 `plugin.json`（允许包一层目录）。若只有 `main.ts` 没有 `main.js`，会尝试用本机 `tsc` 就地编译；id 由 `plugin.json` 的 `id` 或目录名生成（只保留字母数字、`-`、`_`，转小写）。导入后若关键字与已有插件冲突会给出提示，版本变化（新装/升级/降级/同版本覆盖）也会明确写出来
- **检查更新**：插件声明了 `updateUrl` 时可用，见上方「版本与更新」
- **删除**：只能删除用户插件，内置插件会提示「内置插件不能删除」（会一并清除该插件的关键字自定义记录）
- **关键字列**：双击编辑，多个关键字用逗号分隔；冲突时「冲突」列显示被谁占用
- **重置关键字**：清除自定义，恢复 `plugin.json` 的声明
- **打开插件目录**：在 Finder 打开用户插件目录
- **重新加载**：刷新列表并通知宿主重载界面（清空前端插件缓存与图标缓存、重新读取 manifest）

**每次导入/删除/重新加载后都会自动重载插件系统**，无需重启应用。

### 网页一键导入（URL scheme）

ya 注册了两个协议：**`yatools://`**（主）和 `ya://`（别名）。网页可以这样唤起安装：

```
yatools://install?url=<zip 的 https 地址>   # 弹确认窗 → 下载 → 导入 → 自动重载
yatools://ping                              # 探测是否安装（已安装会弹提示）
```

未安装时 `open` 无响应，网页端可在唤起后监听 1.5s 内页面是否失焦，没失焦就跳转下载页。安全限制：只允许 https（`localhost`/`127.0.0.1` 的 http 仅供调试），确认窗必须真人点击。

调试开关（设置环境变量启动二进制时生效）：

```bash
YA_DEBUG=1              # 启动时打印插件列表
YA_IMPORT=/path/a.zip   # 启动时导入指定压缩包
YA_DELETE=<plugin-id>   # 启动时删除指定插件
```

`main.ts` 通过 `__registerPlugin()` 注册插件对象：

```ts
declare const __registerPlugin: (p: any) => void;
declare const callBridge: (action: string, payload?: any) => Promise<any>;
declare const __lang: () => string;

__registerPlugin({
  onQuery(arg, container, api) { /* 输入变化时渲染 */ },
  onKey(e, container, api) { /* 处理按键，返回 true 表示已消费 */ },
  onEnter(api) { /* 进入插件时触发一次 */ },
  onExit() { /* 离开插件时触发 */ },
});
```

`api` 是宿主注入的 API 对象，下面所有能力都通过它调用；也可以直接用全局 `callBridge(action, payload)` 访问底层桥接。

---

## 二、生命周期钩子

| 钩子 | 签名 | 说明 |
| --- | --- | --- |
| `onQuery` | `(arg, container, api, feature?) => void` | **必填**。输入变化时调用，`arg` 为用户输入中去掉关键字后的部分，`container` 为插件渲染容器 DOM，`feature` 为当前入口上下文（见「多入口插件」） |
| `onKey` | `(e, container, api) => boolean` | 可选。键盘事件，返回 `true` 表示事件已被插件消费（宿主不再处理） |
| `onEnter` | `(api) => void` | 可选。插件被激活时触发一次，适合做初始化 |
| `onExit` | `() => void` | 可选。**真正退出插件**时触发（Esc / 切换到别的插件 / 输入不再是本插件关键字），适合做清理。**面板隐藏不触发** —— 面板收起来再呼出会回到原插件（宿主会用当前参数再问一次 `onQuery`），所以要存的数据请在变化时立即写 `api.db`，不要等 `onExit` |
| `onFeature` | `(feature, api) => void` | 可选。**切换入口**时触发一次（含从主入口切进来），`feature.cmd` 为空串表示主入口 |
| `onProvide` | `(query, api) => ProviderItem[] \| Promise<ProviderItem[]>` | 可选。**结果提供者专用**（`plugin.json` 声明 `"provider": true`）。每次搜索把输入原文交给你，返回要插进主列表的结果。300ms 超时 / 抛异常都会本次会话停用，单插件最多 3 条。详见「结果提供者插件」 |

`feature` 的结构：`{ cmd: string, title: string }`，其中 `title` 已按当前语言解析好。

> 对照 uTools：`onQuery` ≈ `onPluginEnter` + `setSubInput` 变更回调，`onExit` ≈ `onPluginOut`。

> ⚠️ 注意：`onEnter` 是「插件被激活」时触发（每次输入命中关键字进入插件都会调用），**不是用户按下 Enter 键**。要响应回车请用 `onKey` 判断 `e.key === "Enter"` 并返回 `true`，否则会在进入插件的瞬间就执行动作。

---

## 三、窗口类 API

| API | 说明 | uTools 对照 |
| --- | --- | --- |
| `api.hide()` | 隐藏启动器面板 | `utools.hideMainWindow()` |
| `api.show()` | 显示启动器面板 | `utools.showMainWindow()` |
| `api.setExpendHeight(height)` | 告诉宿主**插件内容区**要多少 px 高（**建议值**，宿主按统一区间裁决；搜索栏 / 底栏由宿主补，插件不用管） | `utools.setExpendHeight()` |
| `api.setSubInput(handler, placeholder?)` | 让插件接管主输入框 | `utools.setSubInput()` |
| `api.setSubInputValue(text)` | 设置输入框内容（自动带上关键字前缀） | `utools.setSubInputValue()` |
| `api.removeSubInput()` | 取消接管，恢复默认提示语 | `utools.removeSubInput()` |
| `api.showInput(placeholder?)` | 把收起的输入框放出来（配合 `plugin.json` 的 `input`） | — |
| `api.hideInput()` | 重新收起输入框 | — |

### 面板高度（宿主统一决定，插件只给建议值）

`api.setExpendHeight(h)` 里的 `h` 是**插件内容区需要的高度**，宿主会自动加上搜索栏（未收起时）和底栏，
算出面板总高交给原生（搜索态的自动高度是同一个口径）。所以插件按自己的 DOM 去量就行：

```ts
api.setExpendHeight(el.getBoundingClientRect().height + 28); // +28 = #pluginView 上下各 14px
```

这个值只是**建议**：宿主会把它夹到一个统一区间，所有插件一视同仁：

| 情况 | 宿主怎么处理 |
| --- | --- |
| 比刚离开的那份搜索结果矮（或插件还没渲染，什么都不说） | 抬到和搜索结果一样高 —— **切换前后面板总高一模一样**，不会闪 |
| 在两层边界之间 | 按插件说的来（变化小于 40px 不上报，避免每敲一个字窗口都抖） |
| 超过上限（面板 560px 封顶） | 视口停在上界，多出来的内容由 `#pluginView` **内部滚动**，面板不再长高 |

所以：

- **不要**自己去估算外壳尺寸（坑 26：少算底栏的 30 多 px → 内容被挤出一条滚动条）；
- **也不要**在插件里写 `Math.min(MAX_HEIGHT, h)` 之类的封顶（坑 38：各写各的 320 / 520 / 900，
  于是在搜索结果和插件之间来回切换时窗口尺寸一直在换档 —— 用户看到的就是面板在闪）；
- 内容确实很长？让它长到封顶，剩下的交给滚动，宿主已经准备好了。

### 示例：插件接管输入框

```ts
__registerPlugin({
  onEnter(api) {
    api.setSubInput((text) => {
      // text 为用户输入中「关键字之后」的内容
      console.log("用户输入：", text);
    }, "请输入内容…");
  },
  onQuery() {},
  onExit() {
    // 宿主会在离开插件时自动清空 subInput，无需手动调用
  },
});
```

---

## 四、系统类 API

| API | 说明 | uTools 对照 |
| --- | --- | --- |
| `api.notice(body)` | 弹出系统通知（首次调用会申请通知权限） | `utools.showNotification()` |
| `api.openPath(path)` | 用系统默认方式打开文件/文件夹 | `utools.shellOpenPath()` |
| `api.openURL(url)` | 用默认协议打开 URL（http、mailto 等） | `utools.shellOpenExternal()` |
| `api.showInFinder(path)` | 在 Finder 中显示该文件 | `utools.shellShowItemInFolder()` |
| `api.trashItem(path)` | 把文件移到废纸篓 | `utools.shellTrashItem()` |
| `api.beep()` | 播放系统提示音 | `utools.shellBeep()` |
| `api.getPath(name)` | 获取系统特殊目录路径 | `utools.getPath()` |
| `api.getFileIcon(pathOrExt)` | 获取文件/类型的系统图标（返回 base64 Data URL） | `utools.getFileIcon()` |
| `api.getNativeId()` | 设备唯一 ID（首次生成后持久化） | `utools.getNativeId()` |
| `api.getAppInfo()` | 返回 `{ name, version }` | `getAppName()` / `getAppVersion()` |
| `api.isDarkColors()` | 当前是否为深色主题 | `utools.isDarkColors()` |
| `api.lang()` | 当前界面语言：`"zh"` 或 `"en"` | 本项目扩展 |

### `api.getPath(name)` 可用值

`home`、`appData`、`userData`、`temp`、`exe`、`desktop`、`documents`、`downloads`、`music`、`pictures`、`videos`、`logs`

### 示例

```ts
await api.getPath("downloads");            // "/Users/xxx/Downloads"
await api.getFileIcon(".txt");             // "data:image/png;base64,..."
await api.getFileIcon("folder");           // 文件夹图标
api.openPath("/Users/xxx/Downloads/a.pdf");
api.openURL("https://www.apple.com");
api.showInFinder("/Users/xxx/Downloads/a.pdf");
api.notice("任务已完成");
```

---

## 五、剪贴板 API

| API | 说明 | uTools 对照 |
| --- | --- | --- |
| `api.copyText(text)` | 复制文本到系统剪贴板 | `utools.copyText()` |
| `api.getClipboardText()` | 读取剪贴板当前文本 | — |
| `api.getCopiedFiles()` | 读取剪贴板中的文件/文件夹列表 | `utools.getCopyedFiles()` |
| `api.getClipboardHistory()` | 读取宿主维护的剪贴板历史（文本 / 图片 / 文件） | — |
| `api.clipboard.history()` | 同上，结构化条目 | — |
| `api.clipboard.image(id)` | 取该条目的图片缩略图（data URL，无图返回空串） | — |
| `api.clipboard.copy(id)` | 把该条目写回系统剪贴板 | — |
| `api.clipboard.pin(id)` | 收藏 / 取消收藏（收藏项不会被数量上限挤掉） | — |
| `api.clipboard.remove(id)` | 删除该条目 | — |
| `api.clipboard.clear(all?)` | 清空历史；`all` 为 false（默认）时保留收藏项 | — |

历史上限在设置里可调（50 / 100 / 200 / 500，默认 100），超限丢弃最旧的未收藏项；
缩略图单独存 `~/Library/Application Support/ya/clipboard-images/`，最多保留 120 张。

剪贴板历史条目结构：

```ts
{
  id: "3F2A…",                 // 条目 id，删除/收藏/取图都用它
  kind: "text" | "image" | "file",
  text: "复制的文本",           // file 类型为换行拼接的路径
  paths: ["/Users/xxx/a.png"],  // 仅 file 类型
  timestamp: 1790261880,        // 秒级时间戳
  pinned: false,
  hasImage: false               // 有缩略图时可取 api.clipboard.image(id)
}
```

`getCopiedFiles()` 返回结构：

```ts
[{ name: "a.png", path: "/Users/xxx/a.png", isFile: true, isDirectory: false }]
```

---

## 六、存储 API（插件本地键值库）

每个插件拥有独立存储，数据保存在
`~/Library/Application Support/ya/storage/<pluginId>.json`
（与 `plugins/` 分开，避免存储文件被当成插件扫描）。
用法与 localStorage 一致，对应 uTools 的 `utools.dbStorage`。

```ts
await api.db.setItem("key", "value");   // 写入（覆盖）
const v = await api.db.getItem("key");  // 读取，不存在返回 ""
await api.db.removeItem("key");         // 删除
```

> 注意：值为字符串，存对象时自行 `JSON.stringify` / `JSON.parse`。

---

## 七、其他通用能力

| API | 说明 |
| --- | --- |
| `api.esc(html)` | HTML 转义，渲染用户输入时使用，防止破坏 DOM |
| `api.assetUrl(name)` | 插件自带资源（图片/字体）→ data URL，见「插件样式」 |
| `api.callBridge(action, payload)` | 直接调用底层桥接（高级用法） |

底层可用 action（供 `callBridge` 直接调用）：
`hide`、`showMainWindow`、`setPanelHeight`、`movePanel`（`{ x, y }`，鼠标的**屏幕坐标**；配合 `beginPanelDrag` / `endPanelDrag` 由原生按锚点移动窗口并记住位置）、`searchApps`、`launchApp`、
`getIcon`（传 `{ key: "app:<路径>" }` 或 `{ key: "plugin:<id>" }`；命中缓存同步返回 base64，
否则后台生成后由原生调用 `window.__iconReady(key, b64)` 推送——主线程不会因磁盘 IO 卡住）、
`listPlugins`、`loadPlugin`、`setPluginKeyword`（`{ id, keyword: "kw1,kw2" }`）、
`getPluginAsset`（`{ id, name }` → data URL，见「插件样式」）、
`setClipboard`、`getClipboardHistory`、`getClipboardText`、`getCopiedFiles`、
`getClipboardImage`（`{ id }` → data URL）、`restoreClipboardItem`（`{ id }`）、
`toggleClipboardPin` / `removeClipboardItem`（`{ id }`）、`clearClipboard`（`{ all }`）、
`showNotification`、`openPath`、`openURL`、`showInFinder`、`trashItem`、`beep`、
`getPath`、`getFileIcon`、`getNativeId`、`getAppInfo`、`isDarkColors`、
`getLocale`、`getHotKey`（返回当前呼出快捷键的显示文案，如 `⌥Space`）、
`getUsage`、`recordAppUsage`、`recordPluginUsage`、
`dbGet`、`dbSet`、`dbRemove`。

---

## 八、完整示例插件

```ts
// plugins/files/plugin.json
// { "keyword": "file", "name": { "en": "File Tools", "zh": "文件工具" } }

declare const __registerPlugin: (p: any) => void;
declare const __lang: () => string;

let lastPath = "";

__registerPlugin({
  onEnter(api) {
    api.setSubInput(async (text) => {
      if (!text) return;
      const container = document.getElementById("pluginView")!;
      const icon = await api.getFileIcon(text);
      lastPath = text;
      container.innerHTML = `
        <div style="display:flex;gap:12px;align-items:center">
          <img src="${icon}" style="width:32px;height:32px" />
          <div>${api.esc(text)}</div>
        </div>
        <div style="margin-top:8px;color:#888">Enter 在 Finder 中显示</div>`;
    }, "输入文件路径…");
  },
  onKey(e, _container, api) {
    if (e.key === "Enter" && lastPath) {
      api.showInFinder(lastPath);
      api.notice(__lang() === "zh" ? "已在 Finder 中显示" : "Revealed in Finder");
      api.hide();
      return true;
    }
    return false;
  },
  onQuery() {},
  onExit() {
    lastPath = "";
  },
});
```

---

## 九、开发流程

```bash
./build.sh   # 编译 TS + swift build
./run.sh     # 启动（独立会话常驻）
./stop.sh    # 停止
```

新增插件后执行 `./build.sh` 并重启即可生效。
（宿主已不内置插件；独立插件工程见 `~/Desktop/ya-plugin/`，用脚手架 `pnpm build` 产出。）
