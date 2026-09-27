// 多语言文案 + 搜索匹配。
//
// `lang` 定义在这里（同作用域，见 agent.md 坑 15），
// 所以本文件必须排在 shell.ts 之前被 tsc 拼进 shell.js（见 build.sh 的文件顺序）。

const STRINGS: Record<Lang, Record<string, string>> = {
  en: {
    placeholder: "Search apps and plugins: calc / clip",
    footer: "{hk} · ↑↓←→ select · Enter run · Tab enter plugin · Esc back",
    recentUsed: "RECENT",
    appsGroup: "APPS",
    pluginsGroup: "PLUGINS",
    providerGroup: "INSTANT",
    myPlugins: "MY PLUGINS",
    emptyTitle: "Type to search apps and plugins",
    emptySubtitle: "Built-in plugins: calc (Calculator) / clip (Clipboard History)",
    keywordPrefix: "Keyword: ",
    keywordTaken: "Keyword taken by another plugin",
    noResults: "No matches",
    noResultsSub: "Try another keyword",
    ctxUndo: "Undo",
    ctxRedo: "Redo",
    ctxCut: "Cut",
    ctxCopy: "Copy",
    ctxPaste: "Paste",
    ctxSelectAll: "Select All",
  },
  zh: {
    placeholder: "搜索应用和插件：calc / clip",
    footer: "{hk} 呼出 · ↑↓←→ 选择 · Enter 执行 · Tab 进入插件 · Esc 返回",
    recentUsed: "最近使用",
    appsGroup: "应用",
    pluginsGroup: "插件",
    providerGroup: "智能识别",
    myPlugins: "我的插件",
    emptyTitle: "输入关键字搜索应用和插件",
    emptySubtitle: "内置插件：calc（计算器）/ clip（剪贴板历史）",
    keywordPrefix: "关键字：",
    keywordTaken: "关键字已被其他插件占用",
    noResults: "没有匹配结果",
    noResultsSub: "换个关键字试试",
    ctxUndo: "撤销",
    ctxRedo: "重做",
    ctxCut: "剪切",
    ctxCopy: "复制",
    ctxPaste: "粘贴",
    ctxSelectAll: "全选",
  },
};

// 多语言：跟随系统语言，非中文一律英文
let lang: Lang = "en";

function t(key: string): string {
  return STRINGS[lang][key] ?? STRINGS.en[key] ?? "";
}

// 底部提示里的呼出快捷键：原生可配置，取不到时用默认值兜底
let hotKeyText = "Option+Space";

function footerText(): string {
  return t("footer").replace("{hk}", hotKeyText);
}

// 字段可能是纯字符串，也可能是 { en, zh }
function loc(value: any): string {
  if (!value) return "";
  if (typeof value === "string") return value;
  return value[lang] ?? value.en ?? "";
}

// ---- 搜索：插件 + 应用 ----
function isSubsequence(q: string, s: string): boolean {
  if (!q || !s) return false;
  let i = 0;
  for (const ch of q) {
    const found = s.indexOf(ch, i);
    if (found < 0) return false;
    i = found + 1;
  }
  return true;
}

/// 插件匹配：关键字精确 > 关键字前缀 > 名称前缀 > 关键字包含 > 名称包含 >
/// 拼音前缀 > 拼音包含 > 拼音首字母 > 兜底子串
function matchPlugins(q: string): PluginManifest[] {
  if (!q) return [];
  const s = q.toLowerCase();
  const scored: { score: number; m: PluginManifest }[] = [];
  for (const m of manifests) {
    const name = (loc(m.name) || m.id).toLowerCase();
    const pinyin = m.pinyin || { full: "", initials: "" };
    let score = -1;
    if (m.keywords.some((k) => k === s)) score = 0;
    else if (m.keywords.some((k) => k.startsWith(s))) score = 1;
    else if (name.startsWith(s)) score = 2;
    else if (m.keywords.some((k) => k.includes(s))) score = 3;
    else if (name.includes(s)) score = 4;
    else if (pinyin.full.startsWith(s)) score = 5;
    else if (pinyin.full.includes(s)) score = 6;
    else if (isSubsequence(s, pinyin.initials)) score = 7;
    // 兜底子串匹配限定 3 个字符以上，否则单/双字符会把几乎所有插件都匹配出来
    else if (s.length >= 3 && (m.searchText || "").includes(s)) score = 8;
    if (score >= 0) scored.push({ score, m });
  }
  scored.sort((a, b) => a.score - b.score);
  return scored.map((x) => x.m);
}

/// features[] 入口匹配：cmd 精确/前缀 > 显示名包含 > 关键字命中。
/// 只在已命中的插件里找，避免任何插件都能被它的 feature 带出来。
function matchFeatures(
  hits: PluginManifest[],
  q: string
): { m: PluginManifest; f: PluginFeature }[] {
  if (!q) return [];
  const s = q.toLowerCase();
  const scored: { score: number; m: PluginManifest; f: PluginFeature }[] = [];
  for (const m of hits) {
    for (const f of m.features || []) {
      if (!f.keywords.length && !f.cmd) continue; // 关键字全被抢占 → 入口不可用
      const cmd = f.cmd.toLowerCase();
      const title = (loc(f.title) || f.titleText || "").toLowerCase();
      let score = -1;
      if (f.keywords.some((k) => k === s) || cmd === s) score = 0;
      else if (f.keywords.some((k) => k.startsWith(s)) || cmd.startsWith(s)) score = 1;
      else if (title.startsWith(s)) score = 2;
      else if (title.includes(s)) score = 3;
      if (score >= 0) scored.push({ score, m, f });
    }
  }
  scored.sort((a, b) => a.score - b.score);
  return scored.map((x) => ({ m: x.m, f: x.f }));
}
