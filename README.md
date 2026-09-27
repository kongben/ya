# ya — a tiny launcher for macOS

**[简体中文说明请见 README.zh-CN.md](./README.zh-CN.md)**

A global launcher in the spirit of uTools: press **⌥Space** to summon a floating panel,
search and launch local apps, or jump straight into a plugin.

- **Shell**: native Swift / AppKit (hotkey, panel, app index, icons, clipboard, storage)
- **UI & plugins**: `WKWebView` + TypeScript / CSS
- **Requires**: macOS 13.5+, Swift 5.8, built with SwiftPM (no `.xcodeproj`)
- **Author**: zhouyefei

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
>
> `run.sh` prefers `dist/ya.app`: only the `.app` bundle registers the `yatools://`
> URL scheme, so build the app if you want one-click web installs to work.

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
scaffold lives in the sibling `plugin/` repo. A minimal sample is in
[`examples/hello`](examples/hello).

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

---

## Commit convention

Commit messages are written in **English**, Conventional-Commits style:

```
<type>: <imperative summary under 72 chars>

- optional bullet: why, not what
```

Run `./test.sh` before committing. See `agent.md` §13 for the full conventions.
