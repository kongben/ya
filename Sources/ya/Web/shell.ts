// 启动器外壳：应用搜索 + 插件搜索 + 插件调度。
//
// 同目录下的 types / match / ui / edit 由 build.sh 用 `tsc --outFile` 拼在本文件之前，
// 属于**同一个全局作用域**（见 agent.md 坑 15）：
//   types.ts  公共类型（只有类型声明）
//   match.ts  多语言文案 + 搜索匹配（lang 定义在这里）
//   ui.ts     渲染：结果列表 / 布局 / 图标 / 插件 CSS / 面板高度 / 面板拖拽
//   edit.ts   输入框编辑与右键菜单
// 本文件只留「状态 + 调度 + 事件」。

const inputEl = document.getElementById("input") as HTMLInputElement;
const dragbarEl = document.getElementById("dragbar") as HTMLDivElement;
const searchbarEl = document.getElementById("searchbar") as HTMLDivElement;
const resultsEl = document.getElementById("results") as HTMLUListElement;
const pluginViewEl = document.getElementById("pluginView") as HTMLDivElement;
const footerEl = document.getElementById("footer") as HTMLDivElement;
const ctxMenuEl = document.getElementById("ctxMenu") as HTMLDivElement;
const rootEl = document.getElementById("root") as HTMLDivElement;

let manifests: PluginManifest[] = [];
let items: ResultItem[] = [];
let selected = 0;
let mode: "search" | "plugin" = "search";
let activePluginId: string | null = null;
let activePlugin: PluginInstance | null = null;
let activePluginKeyword: string | null = null;
/// 当前所在的插件入口（features[].cmd；主入口为 ""）
let activeFeatureCmd: string | null = null;
let subInputHandler: ((text: string) => void) | null = null;
/// 插件运行中显式要求显示/隐藏输入框（api.showInput / api.hideInput）。
/// null = 未指定，此时按 plugin.json 的 input 字段决定。
let inputOverride: boolean | null = null;
let loadedPlugins = new Map<string, PluginInstance>();
let queryToken = 0;
let panelGeneration = 0; // 面板每次被呼出/重置时 +1，用于丢弃过期的异步结果
let debounceTimer: ReturnType<typeof setTimeout> | null = null;
let isComposing = false; // 输入法组合态（拼音候选未上屏）

/// 插件存储的命名空间：不在插件内时落到 global
function storeScope(): string {
  return activePluginId ?? "global";
}

const api: PluginAPI = {
  // 通用
  callBridge,
  esc: escHtml,
  lang: () => lang,
  // 窗口
  hide: () => callBridge("hide"),
  show: () => callBridge("showMainWindow"),
  /// setExpendHeight 的语义是「**插件内容区**需要多少 px 高」，外壳（搜索栏 + 底栏）由宿主补。
  /// 以前它等于面板总高，插件得自己猜底栏多高 —— 猜错就是内容被挤出一条滚动条（坑 26）。
  /// 搜索栏在插件态通常是离屏的（absolute，不占布局），只有 input:visible / setSubInput 时才算进去。
  ///
  /// 高度不由插件说了算：宿主会把这个值夹到统一区间（坑 38），
  /// 低于搜索结果高度补到齐平（防止切换时跳一下），超过上限就不再顶高面板、改为容器内滚动。
  /// 这样所有插件的面板行为是一致的，插件里不用再写 `Math.min(MAX_HEIGHT, …)` 这类各自为政的封顶。
  setExpendHeight: (height: number) => setPluginViewport(height),
  setSubInput: (handler, placeholder) => {
    subInputHandler = handler;
    if (placeholder) inputEl.placeholder = placeholder;
    // 插件要靠输入框收参数 → 把收起的输入框放出来
    updateInputVisibility();
  },
  setSubInputValue: (text: string) => {
    inputEl.value = (activePluginKeyword ? activePluginKeyword + " " : "") + text;
  },
  removeSubInput: () => {
    subInputHandler = null;
    inputEl.placeholder = t("placeholder");
    updateInputVisibility();
  },
  showInput: (placeholder?: string) => {
    inputOverride = true;
    if (placeholder) inputEl.placeholder = placeholder;
    updateInputVisibility();
  },
  hideInput: () => {
    inputOverride = false;
    updateInputVisibility();
  },
  // 系统
  notice: (body: string) => callBridge("showNotification", { body }),
  openPath: (path: string) => callBridge("openPath", { path }),
  openURL: (url: string) => callBridge("openURL", { url }),
  showInFinder: (path: string) => callBridge("showInFinder", { path }),
  trashItem: (path: string) => callBridge("trashItem", { path }),
  beep: () => callBridge("beep"),
  getPath: (name: string) => callBridge("getPath", { name }),
  getFileIcon: (pathOrExt: string) => callBridge("getFileIcon", { path: pathOrExt }),
  getNativeId: () => callBridge("getNativeId"),
  getAppInfo: () => callBridge("getAppInfo"),
  isDarkColors: () => callBridge("isDarkColors"),
  // 插件自带资源（图片/字体）→ data URL。插件目录不在 WebView 读权限内，只能这样取
  assetUrl: async (name: string) =>
    (await callBridge("getPluginAsset", {
      id: activePluginId ?? "",
      name,
    })) || "",
  // 剪贴板
  copyText: (text: string) => callBridge("setClipboard", { text }),
  getClipboardText: () => callBridge("getClipboardText"),
  getCopiedFiles: () => callBridge("getCopiedFiles"),
  getClipboardHistory: () => callBridge("getClipboardHistory"),
  clipboard: {
    history: () => callBridge("getClipboardHistory"),
    image: (id: string) => callBridge("getClipboardImage", { id }),
    copy: (id: string) => callBridge("restoreClipboardItem", { id }),
    pin: (id: string) => callBridge("toggleClipboardPin", { id }),
    remove: (id: string) => callBridge("removeClipboardItem", { id }),
    clear: (includingPinned?: boolean) =>
      callBridge("clearClipboard", { all: !!includingPinned }),
  },
  // 存储（按当前插件隔离；不在插件内时用 global）
  db: {
    getItem: (key: string) => callBridge("dbGet", { key, plugin: storeScope() }),
    setItem: (key: string, value: string) =>
      callBridge("dbSet", { key, value, plugin: storeScope() }),
    removeItem: (key: string) => callBridge("dbRemove", { key, plugin: storeScope() }),
  },
};

// 插件代码 eval 后通过此函数注册自己
(window as any).__registerPlugin = (p: PluginInstance) => {
  activePlugin = p;
};

async function loadManifests() {
  manifests = await callBridge("listPlugins");
}

// ---- 结果提供者（plugin.json 里 `"provider": true` 的插件）----
//
// 与「接管面板型」插件的区别：它不进插件模式、不碰 DOM，只在每次搜索时被问一句
// "这段输入你认识吗"，把结果交给宿主渲染。万能输入框 / 文件搜索 / Snippets 都是这一类。

/// 单次 onProvide 的超时。这是**每次击键都会跑**的用户代码：宁可丢结果，也不能卡住输入框。
const PROVIDER_TIMEOUT_MS = 300;
/// 单个插件一次最多贡献几条，否则会淹没应用搜索结果
const PROVIDER_MAX_ITEMS = 3;
/// 跑挂过的提供者本次会话内不再问它（否则每次击键都抛一次异常）
const disabledProviders = new Set<string>();

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T | null> {
  return new Promise((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      resolve(null); // 超时当作"这次没结果"，不惩罚插件
    }, ms);
    Promise.resolve(p).then(
      (v) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(v);
      },
      () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(null);
      }
    );
  });
}

/// 给某个插件单独造一份 api：搜索态下 activePluginId 是 null，
/// 直接用全局 api 会让插件的存储读写落到 global 命名空间（坑：Snippets 这类要存东西的会串味）
function scopedApi(id: string): PluginAPI {
  return {
    ...api,
    db: {
      getItem: (key: string) => callBridge("dbGet", { key, plugin: id }),
      setItem: (key: string, value: string) =>
        callBridge("dbSet", { key, value, plugin: id }),
      removeItem: (key: string) => callBridge("dbRemove", { key, plugin: id }),
    },
    assetUrl: async (name: string) =>
      (await callBridge("getPluginAsset", { id, name })) || "",
  };
}

async function collectProviderItems(q: string, token: number): Promise<ResultItem[]> {
  const providers = manifests.filter((m) => m.provider && !disabledProviders.has(m.id));
  if (!providers.length) return [];
  // 并发问，但结果按 manifests 顺序拼 —— 顺序随机会让结果列表每次击键都在跳
  const buckets = await Promise.all(
    providers.map(async (m) => {
      try {
        const inst = await loadPluginInstance(m.id);
        if (!inst?.onProvide) return null;
        const items = await withTimeout(
          Promise.resolve(inst.onProvide(q, scopedApi(m.id))),
          PROVIDER_TIMEOUT_MS
        );
        return items ? items.slice(0, PROVIDER_MAX_ITEMS) : null;
      } catch (e) {
        disabledProviders.add(m.id);
        console.error("结果提供者异常，本次会话已停用:", m.id, e);
        return null;
      }
    })
  );
  if (token !== queryToken) return []; // 输入已经变了，这批结果作废
  const out: ResultItem[] = [];
  providers.forEach((m, i) => {
    for (const p of buckets[i] ?? []) out.push(providerItem(m, p));
  });
  return out;
}

async function doSearch(q: string) {
  const token = ++queryToken;
  const pluginHits = matchPlugins(q); // 插件匹配纯内存，立刻可用
  // 提供者与应用搜索并发跑：别让插件的加载/计算排在应用搜索之后串行等待
  const providerPromise = collectProviderItems(q, token);
  const appRes: any[] = await callBridge("searchApps", { query: q });
  if (token !== queryToken) return;
  const providerItems = await providerPromise;
  if (token !== queryToken) return;

  const newItems: ResultItem[] = [];
  // 提供者结果放最前面：粘贴一串 JSON / 时间戳时，用户要的就是它的结果
  if (providerItems.length) {
    newItems.push({ kind: "header", title: t("providerGroup") });
    for (const it of providerItems) newItems.push(it);
  }
  if (pluginHits.length) {
    newItems.push({ kind: "header", title: t("pluginsGroup") });
    for (const m of pluginHits.slice(0, 6)) newItems.push(pluginItem(m));
    // features[] 声明的额外入口（清剪贴板、截图 OCR…），最多补 3 条，避免刷屏
    for (const hit of matchFeatures(pluginHits, q).slice(0, 3)) {
      newItems.push(pluginFeatureItem(hit.m, hit.f));
    }
  }
  if (appRes.length) {
    newItems.push({ kind: "header", title: t("appsGroup") });
    for (const a of appRes.slice(0, 10)) newItems.push(appItem(a));
  }
  if (!newItems.length) {
    newItems.push(messageItem(t("noResults"), t("noResultsSub")));
  }
  items = newItems;
  selected = firstItemIndex();
  renderResults();
}

// ---- 插件调度 ----

/// 进入插件后默认收起输入框（交互交给插件自己实现），但下面三种情况保留：
/// ① 插件在 plugin.json 里声明 `"input": "visible"`（例如计算器，看不到输入就没法用）
/// ② 插件调用了 api.setSubInput —— 说明它要靠输入框收参数
/// ③ 插件运行时调用了 api.showInput()
///
/// 收起用的是「离屏」而不是 display:none：输入框必须还能聚焦，
/// 否则键盘输入收不到，插件的 onQuery / onKey 会一起失效。
function pluginWantsInput(): boolean {
  if (inputOverride !== null) return inputOverride;
  if (subInputHandler) return true;
  const m = manifests.find((p) => p.id === activePluginId);
  return (m?.input || "").toLowerCase() === "visible";
}

function updateInputVisibility() {
  const off = mode === "plugin" && !pluginWantsInput();
  searchbarEl.classList.toggle("off", off);
  // 收起时 WebKit 可能把焦点从输入框上摘掉，抢回来：
  // 焦点一丢，用户敲的字就进不来，插件的 onQuery / onKey 会一起失灵
  if (off && document.activeElement !== inputEl) inputEl.focus();
}

/// 面板外壳占用的高度：拖拽条 + 搜索栏（在流内时才算，插件态通常是离屏的）+ 底栏 + 边框余量。
/// 搜索态的 autoHeight() 用同一个口径，两边必须一致 ——
/// 漏掉拖拽条的 12px，每次量出来的面板都会矮一截，底栏被挤出一条滚动条。
function panelChromeHeight(): number {
  const bar = searchbarEl.classList.contains("off") ? 0 : searchbarEl.offsetHeight || 0;
  return (dragbarEl.offsetHeight || 0) + bar + (footerEl.offsetHeight || 0) + 16;
}

function setMode(m: "search" | "plugin") {
  mode = m;
  pluginViewEl.classList.toggle("hidden", m === "search");
  resultsEl.classList.toggle("hidden", m !== "search");
  // 插件容器带上自己的作用域 class，插件 CSS 才能落在它里面（见 injectPluginCss）
  if (m === "plugin" && activePluginId) {
    pluginViewEl.classList.add(pluginScopeClass(activePluginId));
  }
  updateInputVisibility();
}

function exitPlugin() {
  if (activePlugin?.onExit) activePlugin.onExit();
  if (activePluginId) pluginViewEl.classList.remove(pluginScopeClass(activePluginId));
  activePlugin = null;
  activePluginId = null;
  activePluginKeyword = null;
  activeFeatureCmd = null;
  subInputHandler = null;
  inputOverride = null;
  inputEl.placeholder = t("placeholder");
  resetPluginViewport(); // 撤掉插件视口的尺寸补丁，让搜索态重新按结果测高
  setMode("search");
}

/// 面板再次被呼出时，如果上回停在插件里（没按 Esc 退出、只是把面板收起来了），
/// 就回到那个插件继续 —— 用户只是切走了一下，把他踢回搜索页等于要重敲一遍关键字。
///
/// 退回搜索页的唯一信号是用户**主动**按 Esc（或输入框内容已经不是这个插件的关键字），
/// 那时 exitPlugin() 已经把状态清干净，这里自然不会命中。
function resumeActivePlugin(): boolean {
  if (mode !== "plugin" || !activePluginId || !activePlugin) return false;
  const m = manifests.find((p) => p.id === activePluginId);
  if (!m) return false; // 这期间插件被卸载/重载过，老状态不可信，回初始页更稳
  const kw = activePluginKeyword || "";
  const raw = inputEl.value;
  const arg =
    kw && raw.toLowerCase().startsWith(kw)
      ? raw.slice(kw.length).replace(/^\s+/, "")
      : raw;
  // 重跑一次 onQuery：面板收起来的这段时间里外部数据可能已经变了
  // （剪贴板插件最典型 —— 用户在别处复制了新内容，回来就得看到新的）。
  // 但**不要** capture/begin 视口：已经在插件里了，重设会把当前高度固化成新下界（坑 38）。
  if (subInputHandler) subInputHandler(arg);
  else activePlugin.onQuery(arg, pluginViewEl, api, featureContext(m, activeFeatureCmd ?? ""));
  return true;
}

/// 回到搜索初始页：清空输入、退出插件、重建初始网格。
/// Esc 的第一级走这里；面板每次呼出也走这里 —— 除非上回停在插件里（见 resumeActivePlugin）。
function resetToSearchInit() {
  inputEl.value = "";
  panelGeneration++; // 作废上一轮呼出/插件遗留的异步结果
  queryToken++;
  if (debounceTimer) {
    clearTimeout(debounceTimer);
    debounceTimer = null;
  }
  exitPlugin();
  lastPanelHeight = 0; // 重新测量：插件可能把面板撑得很高
  showUsage();
}

// 正在加载中的插件，避免并发重复 eval（重复执行会让 __registerPlugin 覆盖实例）
const loadingPlugins = new Map<string, Promise<void>>();

/// 取插件实例（带缓存）。**不会**把它设成 activePlugin —— 结果提供者要在
/// 不接管面板的前提下拿到实例，所以「加载」和「激活」必须拆开。
async function loadPluginInstance(id: string): Promise<PluginInstance | null> {
  if (loadedPlugins.has(id)) return loadedPlugins.get(id) ?? null;
  const pending = loadingPlugins.get(id);
  if (pending) {
    await pending;
    return loadedPlugins.get(id) ?? null;
  }
  const task = (async () => {
    const res = await callBridge("loadPlugin", { id });
    injectPluginCss(id, res.css || "");
    // 插件代码是同步执行的：eval 完 __registerPlugin 已经把实例写进 activePlugin。
    // 先存下旧的再清空，结束后还原 —— 否则给提供者加载插件会把当前插件挤掉。
    const prev = activePlugin;
    activePlugin = null;
    if (res.code) {
      try {
        new Function(res.code)();
      } catch (e) {
        console.error("插件加载失败:", e);
      }
    }
    const inst = activePlugin;
    activePlugin = prev;
    // 只有插件成功注册才写入缓存，避免把 null 缓存住
    if (inst) loadedPlugins.set(id, inst);
  })();
  loadingPlugins.set(id, task);
  await task;
  loadingPlugins.delete(id);
  return loadedPlugins.get(id) ?? null;
}

/// 进入插件前调用：把实例取出并设为当前插件
async function ensurePluginLoaded(id: string) {
  activePlugin = await loadPluginInstance(id);
}

/// 从参数里剥出 feature 命令：`clip clear abc` → cmd=clear, arg=abc
/// 只有首 token 精确等于某个 feature 的 cmd 或关键字时才算命中，否则原样交给主入口。
function resolveFeature(m: PluginManifest, arg: string): { cmd: string; arg: string } {
  const m2 = /^(\S+)\s*([\s\S]*)$/.exec(arg);
  if (!m2) return { cmd: "", arg };
  const token = m2[1].toLowerCase();
  const hit = (m.features || []).find(
    (f) => f.cmd.toLowerCase() === token || f.keywords.some((k) => k === token)
  );
  return hit ? { cmd: hit.cmd, arg: m2[2] } : { cmd: "", arg };
}

/// 关键字 → 插件（可能是某个 feature 的关键字）
function findByPluginKeyword(
  kw: string
): { m: PluginManifest; cmd: string } | null {
  for (const p of manifests) {
    if (p.keywords.indexOf(kw) >= 0) return { m: p, cmd: "" };
    const f = (p.features || []).find((x) => x.keywords.indexOf(kw) >= 0);
    if (f) return { m: p, cmd: f.cmd };
  }
  return null;
}

/// 当前功能的上下文（主入口 cmd 为空串，title 用插件名）
function featureContext(m: PluginManifest, cmd: string): PluginFeatureContext {
  const f = (m.features || []).find((x) => x.cmd === cmd);
  return { cmd: cmd, title: f ? loc(f.title) || f.titleText || f.cmd : loc(m.name) || m.id };
}

/// 判断输入是否落在某个插件上（主入口或 features 入口）
/// 规则：已进入插件时只要输入仍以关键字开头就保持在插件内（继续解析 feature）；
/// 否则必须「关键字 + 空白」才进入（这样输入 cal 时插件只是搜索结果，回车才进入）
function matchPluginInput(raw: string): { m: PluginManifest; arg: string; cmd: string } | null {
  const lower = raw.toLowerCase();
  if (activePluginId) {
    const active = manifests.find((p) => p.id === activePluginId);
    const kw = active?.activateKeyword || "";
    if (kw && lower.startsWith(kw)) {
      const rest = raw.slice(kw.length).replace(/^\s+/, "");
      const r = resolveFeature(active!, rest);
      return { m: active!, arg: r.arg, cmd: r.cmd };
    }
  }
  if (isComposing) return null; // 输入法候选未上屏，不做插件切换
  const m = /^(\S+)\s([\s\S]*)$/.exec(raw);
  if (!m) return null;
  const kw = m[1].toLowerCase();
  const found = findByPluginKeyword(kw);
  if (!found) return null;
  // 走的是 feature 专属关键字 → 命令已确定；走插件主关键字 → 再看参数首 token
  if (found.cmd) return { m: found.m, arg: m[2], cmd: found.cmd };
  const r = resolveFeature(found.m, m[2]);
  return { m: found.m, arg: r.arg, cmd: r.cmd };
}

async function onInput() {
  const raw = inputEl.value;
  const q = raw.trim();
  const gen = panelGeneration;
  const hit = matchPluginInput(raw);

  if (hit) {
    const matched = hit.m;
    const arg = hit.arg;
    if (activePluginId !== matched.id) {
      if (activePlugin?.onExit) activePlugin.onExit();
      activePlugin = null;
      activePluginId = null;
      activePluginKeyword = null;
      activeFeatureCmd = null;
      subInputHandler = null;
      inputOverride = null;
      await ensurePluginLoaded(matched.id);
      if (gen !== panelGeneration) return; // 面板已被重置，本次结果作废
      activePluginId = matched.id;
      activePluginKeyword = matched.activateKeyword;
      if (activePlugin?.onEnter) activePlugin.onEnter(api);
    }
    if (activePlugin) {
      // 只有**刚从搜索态切进来**的这一次才重设视口。插件内继续打字若也走一遍，
      // 会把插件当前的高度固化成新的下界，面板就只会变高、再也缩不回去。
      const entering = mode !== "plugin";
      // 顺序不能改：capture 必须在 setMode 之前（之后结果区被隐藏，就测不到了），
      // begin 必须在 setMode 之后（搜索栏是否离屏已定，外壳高度才算得准）
      if (entering) capturePanelViewport();
      setMode("plugin");
      if (entering) beginPluginViewport(); // 插件还没渲染就把高度定下来，避免先矮后高地闪一下
      // 记录插件使用：进了插件就算，不看有没有带参数。
      // 以前要求「有参数或走 feature 入口」才记，于是敲 `qr` 回车进去用了一通也不会被记，
      // 「最近插件」永远是那一个（配合僵尸 id 不清，症状更明显）。
      callBridge("recordPluginUsage", { id: matched.id });
      const ctx = featureContext(matched, hit.cmd);
      // 入口切换时通知插件一次（清状态、改 UI），主入口 cmd 为空串
      if (activeFeatureCmd !== hit.cmd) {
        activeFeatureCmd = hit.cmd;
        if (activePlugin.onFeature) activePlugin.onFeature(ctx, api);
      }
      // 子输入框优先接管输入，否则交给 onQuery（第四参数带上当前入口）
      if (subInputHandler) subInputHandler(arg);
      else activePlugin.onQuery(arg, pluginViewEl, api, ctx);
    }
    return;
  }

  if (activePluginId) exitPlugin();
  setMode("search");
  if (!q) { showUsage(); return; }
  doSearch(q);
}

// ---- 事件 ----
// 输入防抖：停止打字后才执行查询。输入法组合态用更长延时，减少无效查询
function scheduleInput() {
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(onInput, isComposing ? 220 : 120);
}

inputEl.addEventListener("input", scheduleInput);
inputEl.addEventListener("compositionstart", () => {
  isComposing = true;
});
inputEl.addEventListener("compositionend", () => {
  isComposing = false;
  scheduleInput();
});

inputEl.addEventListener("contextmenu", (e: MouseEvent) => {
  e.preventDefault();
  openCtxMenu(e.clientX, e.clientY);
});
document.addEventListener("mousedown", (e: MouseEvent) => {
  if (ctxMenuEl.classList.contains("hidden")) return;
  if (!ctxMenuEl.contains(e.target as Node)) closeCtxMenu();
});

// 原生在快捷键（重新）注册后推来新文案
(window as any).__setHotKey = (hk: string) => {
  if (typeof hk !== "string" || !hk) return;
  hotKeyText = hk;
  footerEl.textContent = footerText();
};

document.addEventListener("keydown", (e: KeyboardEvent) => {
  // Esc：先关右键菜单（菜单开着时它的语义优先）
  if (e.key === "Escape") closeCtxMenu();

  // 插件态先让插件消费按键（**包括 ⌘/⌃ 组合**，如剪贴板的 ⌘P 收藏 / ⌘⌫ 删除），
  // 返回 true 即代表已处理。顺序不能反：下面的「⌘/⌃ 一律放行」必须排在插件之后，
  // 否则所有带修饰键的插件快捷键都会在到达 onKey 之前被吞掉（坑 24）。
  if (mode === "plugin" && activePlugin) {
    if (activePlugin.onKey && activePlugin.onKey(e, pluginViewEl, api)) {
      e.preventDefault();
      return;
    }
    // Esc 两级退出：插件内先退回搜索初始页，再按一次才隐藏面板
    if (e.key === "Escape") {
      e.preventDefault();
      resetToSearchInit();
      inputEl.focus();
    }
    // 插件没消费的键到此为止；⌘/⌃ 组合交给 AppKit 的 Edit 菜单与 WebKit 默认行为
    return;
  }

  // ⌘/⌃ 组合一律放行：⌘C 复制 / ⌘V 粘贴 / ⌘X 剪切 / ⌘A 全选 / ⌘Z 撤销 …
  // 之前这些键在输入框里是没反应的（宿主没处理、也没菜单项可响应）。
  if (e.metaKey || e.ctrlKey) return;
  if (e.key === "Escape") {
    // 有输入时先清空回初始页；已在初始页才真正关闭
    if (inputEl.value.length > 0) {
      e.preventDefault();
      resetToSearchInit();
      inputEl.focus();
      return;
    }
    callBridge("hide");
    return;
  }
  if (e.key === "ArrowDown") {
    moveSelection(1);
    e.preventDefault();
  } else if (e.key === "ArrowUp") {
    moveSelection(-1);
    e.preventDefault();
  } else if (e.key === "ArrowRight") {
    if (cursorCanMove(1)) return; // 光标还能往右走 → 让浏览器处理
    moveSelection(1, true);
    e.preventDefault();
  } else if (e.key === "ArrowLeft") {
    if (cursorCanMove(-1)) return;
    moveSelection(-1, true);
    e.preventDefault();
  } else if (e.key === "Tab") {
    // Tab：进入当前选中的插件
    const it = items[selected];
    if (it && it.kind === "item" && it.pluginId && it.action) {
      it.action();
      e.preventDefault();
    }
  } else if (e.key === "Enter") {
    const it = items[selected];
    if (it && it.kind === "item" && it.action) {
      it.action();
      // 必须阻止默认动作：进入插件后焦点可能已经切到插件自己的编辑区
      // （textarea / contenteditable），这次回车的默认行为会往那里插一个换行。
      e.preventDefault();
    }
  }
});

// 面板每次被呼出：上回停在插件里就继续那个插件，否则重置回搜索初始页
(window as any).__onPanelShown = () => {
  if (!resumeActivePlugin()) resetToSearchInit();
  inputEl.focus();
};

// ---- 启动 ----
async function boot() {
  const detected = await callBridge("getLocale");
  lang = detected === "zh" ? "zh" : "en";
  document.documentElement.lang = lang;
  (window as any).__lang = () => lang; // 供插件读取当前语言
  inputEl.placeholder = t("placeholder");
  footerEl.textContent = footerText();
  // 不 await：万一原生版本不支持 getHotKey，不能让超时拖住首屏渲染
  callBridge("getHotKey")
    .then((hk: string) => (window as any).__setHotKey(hk))
    .catch(() => {});
  await loadManifests();
  showUsage();
  // 完全就绪（桥接也跑通了）。原生只把这个记进日志，不做白屏判定——
  // 它依赖 callBridge，网络/原生慢时不该被误判成白屏
  (window as any).__yaBooted = true;
}

// 脚本执行到底的标记。原生靠它判断白屏：shell.js 是 tsc --outFile 拼出来的，
// 任意一处顶层重名（见坑 15）都会让整个文件报语法错误、一行都不执行——
// 这时页面是全白的，但这个标记不会置位，原生就能发现并重载一次
(window as any).__yaScriptLoaded = true;
boot();
inputEl.focus();
setupPanelDrag();
