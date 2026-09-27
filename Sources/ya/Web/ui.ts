// 渲染层：结果列表 / 二维布局 / 图标 / 插件 CSS 注入 / 面板高度 / 面板拖拽。
//
// 这里只定义函数与「属于渲染自己的状态」，宿主外壳的状态（items / selected / mode …）
// 定义在 shell.ts —— 同作用域直接读（tsc --outFile 合成单文件，见 agent.md 坑 15）。

function escHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c] as string));
}

/**
 * 注入插件 CSS。
 *
 * 三件事，缺一个插件样式就会出问题：
 * 1. **作用域隔离**：插件 CSS 直接进 <head> 会全局生效，`div {}` / `.item-title` 之类的
 *    选择器会污染宿主 shell 和其它插件。这里用 CSSOM 给每条选择器加上 `.ya-plugin-<id>`
 *    前缀，规则只落在插件容器里。（CSSOM 改写失败时退回原样注入，保证样式至少能用。）
 * 2. **可卸载**：<style> 带 id，重复注入前先移除旧的，否则插件重载一次就多一份。
 * 3. **资源**：相对 url() 已由原生换成 data URL（WebView 读不到插件目录，见 PluginLoader）。
 */
function injectPluginCss(id: string, css: string) {
  const styleId = `ya-plugin-css-${id}`;
  document.getElementById(styleId)?.remove();
  if (!css) return;

  const style = document.createElement("style");
  style.id = styleId;
  style.textContent = css;
  document.head.appendChild(style);

  const prefix = pluginScopeClass(id);
  try {
    const rules = (style.sheet as CSSStyleSheet | null)?.cssRules;
    if (!rules) return;
    scopeRules(rules, prefix);
  } catch {
    // CSSOM 不可用时保持原样（样式仍生效，只是没有隔离）
  }
}

function pluginScopeClass(id: string): string {
  return `ya-plugin-${id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
}

function scopeRules(rules: CSSRuleList, prefix: string) {
  for (let i = 0; i < rules.length; i++) {
    const rule = rules[i] as CSSRule & { selectorText?: string; cssRules?: CSSRuleList };
    if (rule.selectorText) {
      rule.selectorText = scopeSelector(rule.selectorText, prefix);
      continue;
    }
    // @media / @supports 等：递归处理内层规则；@keyframes / @font-face 无选择器，原样保留
    if (rule.cssRules) scopeRules(rule.cssRules, prefix);
  }
}

function scopeSelector(selector: string, prefix: string): string {
  return selector
    .split(",")
    .map((part) => {
      const seg = part.trim();
      if (!seg) return seg;
      // 页面级选择器（html/body/:root/#pluginView）映射到插件容器自身，
      // 否则插件没法给自己的根容器设样式、也没法定 CSS 变量
      if (/^(html|body|:root|#pluginView)\b/i.test(seg)) return "." + prefix;
      return `.${prefix} ${seg}`;
    })
    .join(", ");
}

// ---- 图标：缓存优先，未命中异步拉取（原生后台生成后推送 __iconReady）----
// 图标缓存：iconKey -> dataURL，每个 key 只向原生拉取一次
const iconCache = new Map<string, string>();
const pendingIcons = new Set<string>();

function applyIcon(key: string, b64: string) {
  if (!b64) return;
  const url = `data:image/png;base64,${b64}`;
  iconCache.set(key, url);
  pendingIcons.delete(key);
  const dots = resultsEl.querySelectorAll(`[data-icon-for="${CSS.escape(key)}"]`);
  if (!dots.length) return;
  const img = document.createElement("img");
  img.src = url;
  dots.forEach((dot, n) => dot.replaceWith(n === 0 ? img : img.cloneNode()));
}

function requestIcon(key: string) {
  if (!key || iconCache.has(key) || pendingIcons.has(key)) return;
  pendingIcons.add(key);
  callBridge("getIcon", { key }).then((b64: string) => {
    if (b64) applyIcon(key, b64);
    else pendingIcons.delete(key); // 交给原生异步推送
  });
}

(window as any).__iconReady = (key: string, b64: string) => {
  applyIcon(key, b64);
};

// ---- 结果项 ----
function appItem(a: any, grid = false): ResultItem {
  return {
    kind: "item",
    title: a.name,
    iconKey: "app:" + a.path,
    grid: grid,
    action: () => {
      callBridge("recordAppUsage", { name: a.name, path: a.path });
      callBridge("launchApp", { path: a.path });
      callBridge("hide");
    },
  };
}

function pluginItem(m: PluginManifest, grid = false): ResultItem {
  const conflicted = !!m.conflictWith;
  // 网格卡片没有副标题，用 ⚠ 标记关键字被抢占
  const title = (loc(m.name) || m.id) + (grid && conflicted ? " ⚠" : "");
  const sub = conflicted
    ? t("keywordTaken")
    : loc(m.description) || `${t("keywordPrefix")}${m.activateKeyword}`;
  return {
    kind: "item",
    title: title,
    subtitle: grid ? undefined : sub,
    iconKey: m.iconKey,
    pluginId: m.id,
    grid: grid,
    action: () => {
      const kw = m.activateKeyword;
      if (!kw) return;
      inputEl.value = kw + " ";
      void onInput();
    },
  };
}

/// features[] 里的额外入口也可以直接当作搜索结果，回车进入对应功能
function pluginFeatureItem(m: PluginManifest, f: PluginFeature): ResultItem {
  const base = loc(m.name) || m.id;
  const title = `${base} · ${loc(f.title) || f.titleText || f.cmd}`;
  const kw = m.activateKeyword;
  return {
    kind: "item",
    title: title,
    subtitle: `${t("keywordPrefix")}${kw} ${f.cmd}`,
    iconKey: m.iconKey,
    pluginId: m.id,
    action: () => {
      if (!kw) return;
      inputEl.value = `${kw} ${f.cmd} `;
      void onInput();
    },
  };
}

/// 结果提供者插件贡献的一条结果 → 宿主列表项。
///
/// 图标默认用插件自己的图标；插件没给 `action` 时走「打开链接 + 复制 + 收起面板」
/// 这套默认动作（与迁移前万能输入框的行为一致）。
function providerItem(m: PluginManifest, p: ProviderItem): ResultItem {
  return {
    kind: "item",
    title: oneLine(p.title, 90),
    subtitle: p.subtitle ? oneLine(p.subtitle, 60) : undefined,
    swatch: p.swatch,
    iconKey: m.iconKey,
    pluginId: m.id,
    action: () => {
      if (p.action) {
        p.action();
        return;
      }
      if (p.openURL) callBridge("openURL", { url: p.openURL });
      if (p.copy) callBridge("setClipboard", { text: p.copy });
      callBridge("hide");
    },
  };
}

/// 标题/副标题统一单行截断：插件可能给出超长内容，会撑破一行
function oneLine(text: string, max: number): string {
  const flat = (text || "").replace(/\s+/g, " ").trim();
  return flat.length > max ? flat.slice(0, max) + "…" : flat;
}

/// 能否被「关键字 + 空格」唤醒。纯结果提供者可能一个关键字都没有，
/// 它只在搜索结果里出现，不能作为插件卡片被点进去（点进去也没东西可显示）
function isEnterable(m: PluginManifest): boolean {
  return !!m.activateKeyword;
}

/// 纯提示性的结果项（初始页空态 / 搜索无结果）
function messageItem(title: string, subtitle: string): ResultItem {
  return { kind: "item", title: title, subtitle: subtitle };
}

function firstItemIndex(): number {
  const idx = items.findIndex((it) => it.kind === "item");
  return idx < 0 ? 0 : idx;
}

// ---- 二维布局：让 ↑↓ 能跨分组移动 ----
const GRID_COLS = 6; // 必须与 shell.css 里 .grid 的列数一致
// 渲染时给每个可选中的项算出它在屏幕上的 (行, 列)：
// 网格卡片每行 GRID_COLS 个；分组标题独占一行；列表项占满一行（col=0）。
// 有了这张表，方向键就能"走到屏幕上真正相邻的那一项"，而不是靠索引加减猜。
interface CellPos { row: number; col: number; }
let layout = new Map<number, CellPos>(); // items 下标 -> 行列
let rowItems = new Map<number, number[]>(); // 行 -> 该行的 items 下标（按列升序）
let maxRow = 0;

function buildLayout() {
  layout = new Map();
  rowItems = new Map();
  let row = 0;
  let col = 0;
  const push = (idx: number) => {
    layout.set(idx, { row, col });
    const list = rowItems.get(row);
    if (list) list.push(idx);
    else rowItems.set(row, [idx]);
    maxRow = Math.max(maxRow, row);
  };
  const nextRow = () => { row += 1; col = 0; };

  items.forEach((it, i) => {
    if (it.kind === "header") {
      if (col > 0) nextRow(); // 结束上一组没填满的行
      nextRow();              // 标题本身占一行
      return;
    }
    if (it.grid) {
      push(i);
      col += 1;
      if (col >= GRID_COLS) nextRow();
      return;
    }
    if (col > 0) nextRow();
    push(i);
    nextRow();
  });
}

function renderResults() {
  resultsEl.innerHTML = "";
  buildLayout();
  let gridEl: HTMLElement | null = null; // 当前正在填充的网格容器
  items.forEach((it, i) => {
    const key = it.iconKey || "";
    const cached = key ? iconCache.get(key) : undefined;
    // 用 iconKey 而非行号定位占位符：列表重排后行号会变，可能把图标填到错误的行
    const iconHtml = cached
      ? `<img src="${cached}" />`
      : `<span class="dot" data-icon-for="${escHtml(key)}"></span>`;

    if (it.kind === "header") {
      gridEl = null; // 新分组结束上一个网格
      const li = document.createElement("li");
      li.className = "group";
      li.innerHTML = `<div class="item-title group-title">${escHtml(it.title || "")}</div>`;
      resultsEl.appendChild(li);
      return;
    }

    // 网格卡片：连续的同组卡片塞进同一个 .grid 容器（一行 6 个）
    if (it.grid) {
      if (!gridEl) {
        const row = document.createElement("li");
        row.className = "gridrow";
        gridEl = document.createElement("div");
        gridEl.className = "grid";
        row.appendChild(gridEl);
        resultsEl.appendChild(row);
      }
      const cell = document.createElement("div");
      cell.className = i === selected ? "cell sel" : "cell";
      cell.innerHTML = `${iconHtml}<div class="cell-name">${escHtml(it.title || "")}</div>`;
      if (it.action) cell.onclick = () => it.action!();
      gridEl.appendChild(cell);
      if (!cached && key) requestIcon(key);
      return;
    }

    gridEl = null;
    const li = document.createElement("li");
    if (i === selected) li.className = "sel";
    // 色块：万能输入框的颜色识别结果（没有图标时的左侧视觉标识）
    const lead = it.swatch
      ? `<span class="swatch" style="background:${escHtml(it.swatch)}"></span>`
      : key
        ? iconHtml
        : `<span class="dot"></span>`;
    li.innerHTML = `${lead}<div class="item-main"><div class="item-title">${escHtml(it.title || "")}</div>${it.subtitle ? `<div class="item-sub">${escHtml(it.subtitle)}</div>` : ""}</div>`;
    if (it.action) li.onclick = () => it.action!();
    resultsEl.appendChild(li);
    if (!it.swatch && !cached && key) requestIcon(key);
  });
  autoHeight();
}

/// 方向键移动选中项，按屏幕上的真实行列走：
/// ↑↓ 跨行（会跨过分组标题，所以三组网格之间是打通的），←→ 在本行内左右挪。
function moveSelection(delta: number, horizontal = false) {
  const cur = layout.get(selected);
  if (!cur) return;
  let target: number | undefined;

  if (horizontal) {
    const cells = rowItems.get(cur.row) || [];
    const pos = cells.indexOf(selected);
    target = cells[pos + delta]; // 越界即 undefined → 不移动
  } else {
    // 往目标方向找第一个有内容的行（分组标题行是空的，会被自然跳过）
    let r = cur.row + delta;
    while (r >= 0 && r <= maxRow && !(rowItems.get(r) || []).length) r += delta;
    if (r < 0 || r > maxRow) return;
    const cells = rowItems.get(r) || [];
    // 保持列位置；目标行没那么宽时，落到该行最接近的那一列
    target = cells.reduce((best, idx) =>
      Math.abs(layout.get(idx)!.col - cur.col) < Math.abs(layout.get(best)!.col - cur.col)
        ? idx : best, cells[0]);
  }

  if (target === undefined) return;
  selected = target;
  renderResults();
}

// ---- 初始状态：最近使用（应用 + 插件混排）----
/// 「最近使用」最多几条 = 两排。应用和插件共用这份额度，谁最近谁在前
const RECENT_MAX = GRID_COLS * 2;

async function showUsage() {
  const token = ++queryToken;
  const usage = await callBridge("getUsage");
  if (token !== queryToken) return;
  const newItems: ResultItem[] = [];

  // 一条时间线：原生按「最后使用时间」把应用和插件混在一起排好（见 UsageHistory），
  // 以前是两个分组，刚用过的插件会被压在整排应用后面 —— 那不叫最近使用。
  // 拿到的 id 已经由原生过滤过（不存在的插件会被清掉），这里还要按 isEnterable 再滤一次：
  // 纯结果提供者没有关键字，点进去没东西可显示，不该占卡片位。
  const recent: any[] = usage.recent || [];
  const recentItems: ResultItem[] = [];
  for (const e of recent) {
    if (recentItems.length >= RECENT_MAX) break;
    if (e.kind === "app") {
      recentItems.push(appItem(e, true));
      continue;
    }
    const m = manifests.find((x) => x.id === e.id);
    if (m && isEnterable(m)) recentItems.push(pluginItem(m, true));
  }
  // 卡片排布（一行 6 个），比一行一个条目省一半以上纵向空间
  if (recentItems.length) {
    newItems.push({ kind: "header", title: t("recentUsed") });
    for (const it of recentItems) newItems.push(it);
  }

  // 「我的插件」必须是**全部**已安装插件：以前会把「最近插件」里出现过的过滤掉，
  // 用户数着数着就以为「导入的插件少了一个」（坑 29）。允许与上面重复。
  const enterable = manifests.filter(isEnterable);
  if (enterable.length) {
    newItems.push({ kind: "header", title: t("myPlugins") });
    for (const m of enterable) newItems.push(pluginItem(m, true));
  }

  if (!newItems.length) {
    newItems.push(messageItem(t("emptyTitle"), t("emptySubtitle")));
  }
  items = newItems;
  selected = firstItemIndex();
  renderResults();
}

// ---- 面板高度 ----
/// 面板总高的上下限。**搜索态与插件态共用**，以前插件各自封顶（320 / 900 都有），
/// 于是在搜索结果和插件之间来回切一次，窗口就换一档尺寸，看着像页面在闪。
const PANEL_MIN_HEIGHT = 200;
const PANEL_MAX_HEIGHT = 560;

/// 插件内容视口的**绝对下界**。只有当「进插件前没测到搜索态高度」（面板刚呼出、
/// 还没渲染过任何结果）时才真正起作用，正常情况下视口跟着搜索结果走。
const PLUGIN_VIEWPORT_FLOOR = 240;
/// 高度变化小于这个值就不上报：插件每敲一个字都会重新自报高度，
/// 全量上报等于让窗口跟着抖动
const PLUGIN_HEIGHT_HYSTERESIS = 40;

let lastPanelHeight = 0;
/// 进入插件**前**那一刻的面板总高（插件视口 = 它 − 插件态外壳）
let searchPanelHeight = 0;
/// 当前生效的插件内容视口高度
let pluginViewportHeight = 0;

function clampSize(v: number, lo: number, hi: number): number {
  if (!Number.isFinite(v)) return lo;
  return Math.min(Math.max(v, lo), Math.max(hi, lo));
}

/// 插件内容区最多能长到多少：面板封顶减去当前外壳（输入框可能还在占位置）
function pluginViewportMax(): number {
  return Math.max(PANEL_MAX_HEIGHT - panelChromeHeight(), PLUGIN_VIEWPORT_FLOOR);
}

/// 插件内容视口的下界：默认**接住刚离开的那份搜索结果的高度**，
/// 所以「搜索 → 插件」的那一帧面板总高一模一样（搜索栏让出来的空间归插件内容区）。
/// 这样插件哪怕在第一次 setExpendHeight 之前是空的，也不会先矮一截再撑开。
function pluginViewportMin(): number {
  const keep = searchPanelHeight > 0 ? searchPanelHeight - panelChromeHeight() : 0;
  return clampSize(keep, PLUGIN_VIEWPORT_FLOOR, pluginViewportMax());
}

function autoHeight() {
  if (mode !== "search") return; // 插件视图的高度走 applyPluginViewport
  const height =
    dragbarEl.offsetHeight +
    searchbarEl.offsetHeight +
    resultsEl.offsetHeight +
    footerEl.offsetHeight +
    16;
  if (!Number.isFinite(height)) return;
  const target = clampSize(height, PANEL_MIN_HEIGHT, PANEL_MAX_HEIGHT);
  if (lastPanelHeight > 0 && Math.abs(target - lastPanelHeight) < 40) return;
  lastPanelHeight = target;
  callBridge("setPanelHeight", { height: target });
}

/// 进入插件的第一步：记下当前面板总高。
/// **必须早于 setMode('plugin')** —— 之后搜索栏离屏、结果区被隐藏，两个都测不到了。
function capturePanelViewport() {
  searchPanelHeight = lastPanelHeight;
}

/// 进入插件：把视口钉在下界并**立刻**上报（force）。
/// 不等插件第一次 setExpendHeight 是很关键的：那段代码要加载 JS、跑 DOM 渲染，
/// 等它算完再改高度，用户看到的就是"面板先亮出来一个尺寸、再跳一下"。
function beginPluginViewport() {
  pluginViewportHeight = 0; // 换插件了，别沿用上一个插件留下的滞后基准
  applyPluginViewport(pluginViewportMin(), true);
}

/// 所有插件统一走这一个出口：插件只管按自己的 DOM 量高度，边界由宿主裁。
/// - 比搜索结果矮 → 补到下界（防止面板缩一下）
/// - 在 [下界, 上界] 之间 → 按插件说的来
/// - 超过上界 → 视口停在上界，多出来的内容由 #pluginView 内部滚动
function setPluginViewport(height: number) {
  if (mode !== "plugin") return;
  applyPluginViewport(height);
}

function applyPluginViewport(height: number, force = false) {
  const target = clampSize(height, pluginViewportMin(), pluginViewportMax());
  if (
    !force &&
    pluginViewportHeight > 0 &&
    Math.abs(target - pluginViewportHeight) < PLUGIN_HEIGHT_HYSTERESIS
  ) {
    return;
  }
  pluginViewportHeight = target;
  lastPanelHeight = target + panelChromeHeight();
  // min == max：视口高度在这一刻是确定的。超出的内容滚动，而不是把面板继续顶高 ——
  // 面板每顶一次，用户就看到一次窗口尺寸跳变
  pluginViewEl.style.minHeight = `${target}px`;
  pluginViewEl.style.maxHeight = `${target}px`;
  callBridge("setPanelHeight", { height: lastPanelHeight });
}

/// 退出插件：撤掉给容器打的尺寸补丁，并让 autoHeight 重新测量。
/// 不清 lastPanelHeight 的话，搜索态会被插件留下的高度卡在滞后区里缩不回来。
function resetPluginViewport() {
  pluginViewportHeight = 0;
  searchPanelHeight = 0;
  lastPanelHeight = 0;
  pluginViewEl.style.minHeight = "";
  pluginViewEl.style.maxHeight = "";
}

// ---- 面板拖拽：整块面板都能拖，但交互元素除外 ----
//
// 拖拽会与「点击结果项」「拖选文本」抢手势，所以：
// 1. mousedown 落在输入框 / 按钮 / 链接 / 结果项上时不拖（它们是拿来点的、拿来选的）；
// 2. 移动超过阈值才算拖拽，并在 mouseup 后吃掉那一次 click（否则松手会误触发结果）；
// 3. **只上报鼠标的屏幕坐标，位置由原生按锚点算**（见坑 28）：
//    - 不能用 clientX/clientY 算增量：窗口一动，鼠标相对视口的坐标就反向变一次，
//      增量里于是混进了「窗口自己刚才移动了多少」→ 正反馈来回抖；
//    - 也不能每个 mousemove 都等一次桥接回包：一秒几十次 evaluateJavaScript 回灌主线程，
//      窗口移动会一卡一卡的（看起来也像抖）。这里 rAF 合并 + 不等回包。
const DRAG_THRESHOLD = 4;
const DRAG_EXCLUDE = "input, textarea, select, button, a, [contenteditable], #results li, #results .cell, #ctxMenu";
/// 顶部专用拖拽条。整块面板都能拖，但那是为了顺手，不是一个能看见的入口；
/// 这条带抓手的地方按下**就是要拖**，所以不走阈值（不然轻推 2px 面板不动，会被当成坏了）。
const DRAG_BAR = "#dragbar";

function setupPanelDrag() {
  let dragging = false;
  let moved = false;
  let onBar = false; // 这次按下是不是落在顶部拖拽条上
  let startX = 0; // 按下时的鼠标屏幕坐标
  let startY = 0;
  let pendingX = 0; // 最近一次待上报的鼠标屏幕坐标
  let pendingY = 0;
  let raf = 0;

  rootEl.addEventListener("mousedown", (e: MouseEvent) => {
    if (e.button !== 0) return;
    const target = e.target as HTMLElement | null;
    if (target?.closest(DRAG_EXCLUDE)) return;
    onBar = !!target?.closest(DRAG_BAR);
    dragging = true;
    moved = false;
    startX = e.screenX;
    startY = e.screenY;
    pendingX = e.screenX;
    pendingY = e.screenY;
    // 锚点：让原生记下「此刻窗口原点 + 此刻鼠标屏幕位置」，之后只按鼠标位移算新原点
    postBridge("beginPanelDrag", { x: startX, y: startY });
    // 鼠标甩出面板外也要跟得上（面板边缘很窄，拖快了很容易出去）
    const pid = (e as any).pointerId;
    if (pid !== undefined) {
      try { rootEl.setPointerCapture(pid); } catch { /* 没有就算了 */ }
    }
    // 这里**绝不能** preventDefault（坑 25）：WebKit 上会连随后的 click 一起吞掉，
    // 插件自己画的交互（剪贴板「点一行就复制」、其它插件的按钮）会全部失灵。
    // 拖过容易带走选区的问题改在下面真正开始拖动时清掉。
  });

  window.addEventListener("mousemove", (e: MouseEvent) => {
    if (!dragging) return;
    // 拖拽条上按下 = 明确的拖拽意图，不必再等 4px 阈值
    const threshold = onBar ? 0 : DRAG_THRESHOLD;
    if (!moved && Math.abs(e.screenX - startX) + Math.abs(e.screenY - startY) < threshold) return;
    if (!moved) {
      moved = true;
      // 拖起来了：先清掉可能被拖出来的选区（面板本身不该有选区），
      // 等价于当年在 mousedown 里 preventDefault 的效果，但不会吃掉 click
      window.getSelection?.()?.removeAllRanges();
      if (onBar) dragbarEl.classList.add("dragging");
    }
    pendingX = e.screenX;
    pendingY = e.screenY;
    // 一帧最多上报一次；丢帧无所谓，因为报的是绝对坐标，下一帧自然会补上
    if (!raf) {
      raf = requestAnimationFrame(() => {
        raf = 0;
        postBridge("movePanel", { x: pendingX, y: pendingY });
      });
    }
  });

  window.addEventListener("mouseup", () => {
    if (!dragging) return;
    dragging = false;
    onBar = false;
    dragbarEl.classList.remove("dragging");
    if (raf) {
      cancelAnimationFrame(raf);
      raf = 0;
    }
    if (moved) {
      // 补上最后一帧，再让原生落盘（拖拽过程中不写 UserDefaults，避免一路 I/O 卡顿）
      postBridge("movePanel", { x: pendingX, y: pendingY });
      postBridge("endPanelDrag", {});
    }
    if (!moved) {
      // 没拖动 = 一次普通点击。mousedown 不再 preventDefault 后，点在非可聚焦元素上
      // 会把焦点甩给 body（宿主输入框丢焦点 → 后面敲字全丢），这里把焦点抢回来。
      // 插件自己的输入框/textarea 已拿到焦点时不动它。
      const active = document.activeElement;
      if (!active || active === document.body) inputEl.focus();
      return;
    }
    // 拖完的这一次 click 要吃掉，否则会误执行刚拖过的那个结果项
    window.addEventListener(
      "click",
      (ev) => { ev.stopPropagation(); ev.preventDefault(); },
      { capture: true, once: true }
    );
  });
}
