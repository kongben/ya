// 初始页分组（Sources/ya/Web/ui.ts 的 showUsage）
//
// 坑 29：装了 3 个插件，初始页「我的插件」只显示 2 个、「最近插件」永远 1 个。
// 根因是「我的插件」把最近插件里出现过的剔除掉了 —— 这里把分组规则钉死。
//
// 现在「最近使用」是**应用和插件共用一条时间线**（原生 UsageHistory 记录），
// 最多 12 个 = 两排卡片。以前是「最近应用」+「最近插件」两组，刚用过的插件会被压在应用后面。
import test from "node:test";
import assert from "node:assert/strict";
import { bootShell, plugin } from "./harness.mjs";

const THREE = [
  plugin("clipboard", "剪贴板历史", ["clip", "cb"]),
  plugin("qrcode", "二维码", ["qr", "ewm"]),
  plugin("urlc", "URL 编解码", ["urlc"]),
];

/** 把 items 压成可读的行：分组用 #，条目用 - */
function outline(h) {
  return h.json(`items.map(i => (i.kind === 'header' ? '#' + i.title : '-' + i.title))`);
}

const app = (name) => ({ kind: "app", name, path: `/Applications/${name}.app` });
const plug = (id) => ({ kind: "plugin", id });

test("最近使用是应用和插件混排的一条时间线", async () => {
  const h = await bootShell({
    plugins: THREE,
    usageRecent: [app("Safari"), plug("qrcode"), app("备忘录"), plug("clipboard")],
  });
  try {
    assert.deepEqual(outline(h).slice(0, 5), [
      "#最近使用",
      "-Safari",
      "-二维码",
      "-备忘录",
      "-剪贴板历史",
    ]);
  } finally {
    h.close();
  }
});

test("最近使用最多 12 个（两排）", async () => {
  // 15 个插件 + 5 个应用交错，只该留下前 12 个
  const many = Array.from({ length: 15 }, (_, i) => plugin(`p${i}`, `插件${i}`, [`k${i}`]));
  const recent = [];
  for (let i = 0; i < 15; i++) {
    recent.push(plug(`p${i}`));
    if (i < 5) recent.push(app(`App${i}`));
  }
  const h = await bootShell({ plugins: many, usageRecent: recent });
  try {
    const lines = outline(h);
    const mine = lines.indexOf("#我的插件");
    assert.equal(mine, 13, "1 个分组标题 + 12 个卡片");
    assert.equal(lines[0], "#最近使用");
    assert.equal(lines[1], "-插件0");
  } finally {
    h.close();
  }
});

test("我的插件必须是全部已安装插件，不被最近使用吃掉", async () => {
  const h = await bootShell({ plugins: THREE, usageRecent: [plug("qrcode")] });
  try {
    assert.deepEqual(outline(h), [
      "#最近使用",
      "-二维码",
      "#我的插件",
      "-剪贴板历史",
      "-二维码",
      "-URL 编解码",
    ]);
  } finally {
    h.close();
  }
});

test("没有使用记录时也要列出全部插件", async () => {
  const h = await bootShell({ plugins: THREE });
  try {
    assert.deepEqual(outline(h), ["#我的插件", "-剪贴板历史", "-二维码", "-URL 编解码"]);
  } finally {
    h.close();
  }
});

test("使用记录里的僵尸 id（插件已删/改过 id）不显示", async () => {
  const h = await bootShell({
    plugins: THREE,
    usageRecent: [plug("ghost"), app("Safari"), plug("urlc")],
  });
  try {
    const lines = outline(h);
    assert.ok(!lines.includes("-ghost"));
    assert.deepEqual(lines.slice(0, 3), ["#最近使用", "-Safari", "-URL 编解码"]);
  } finally {
    h.close();
  }
});

test("纯结果提供者（无关键字）不占最近使用的卡片位", async () => {
  const h = await bootShell({
    plugins: [
      plugin("smart", "万能输入框", [], { provider: true, activateKeyword: "" }),
      ...THREE,
    ],
    usageRecent: [plug("smart"), plug("urlc")],
  });
  try {
    const lines = outline(h);
    assert.ok(!lines.includes("-万能输入框"), "点进去没东西可显示，不该出现在卡片里");
    assert.deepEqual(lines.slice(0, 2), ["#最近使用", "-URL 编解码"]);
  } finally {
    h.close();
  }
});

test("最近使用的应用点了会记录并启动", async () => {
  const h = await bootShell({ plugins: THREE, usageRecent: [app("Safari")] });
  try {
    h.run("items.find(i => i.title === 'Safari').action()");
    const calls = h.json("__calls.map(c => c.action)");
    assert.ok(calls.includes("recordAppUsage"));
    assert.ok(calls.includes("launchApp"));
  } finally {
    h.close();
  }
});

test("什么都没有时给一条空态提示，而不是空白面板", async () => {
  const h = await bootShell();
  try {
    const lines = outline(h);
    assert.equal(lines.length, 1);
    assert.ok(lines[0].startsWith("-"), "空态是一条普通条目，不是分组标题");
    assert.ok(lines[0].includes("输入关键字"), lines[0]);
  } finally {
    h.close();
  }
});

test("初始页的选中项是第一个可选条目（跳过分组标题）", async () => {
  const h = await bootShell({ plugins: THREE });
  try {
    assert.equal(h.get("selected"), h.get("firstItemIndex()"));
    assert.equal(h.json("items[selected].kind"), "item");
  } finally {
    h.close();
  }
});

test("关键字被抢占的插件仍可进入（activateKeyword 兜底）", async () => {
  const h = await bootShell({
    plugins: [plugin("loser", "被抢占", [], { conflictWith: "winner", activateKeyword: "loser" })],
  });
  try {
    const items = h.json("items");
    const it = items.find((i) => i.pluginId === "loser");
    assert.ok(it, "冲突的插件也要出现在我的插件里");
    // action 会把关键字填进输入框
    h.run("items.find(i => i.pluginId === 'loser').action()");
    assert.equal(h.doc.getElementById("input").value, "loser ");
  } finally {
    h.close();
  }
});
