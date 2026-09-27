// 面板「再次呼出」的行为（Sources/ya/Web/shell.ts 的 __onPanelShown）
//
// 规则：上回停在插件里（没按 Esc 退出、只是把面板收起来了）→ 回到那个插件继续；
// 主动按 Esc 退出了 → 回搜索初始页。
import test from "node:test";
import assert from "node:assert/strict";
import { bootShell, plugin } from "./harness.mjs";

/// 假插件：只记录自己被问了几次、进出各几次，不碰 DOM
const CODE =
  "window.__registerPlugin({" +
  "  onQuery: (a) => { window.__queries = (window.__queries || []).concat(a); }," +
  "  onEnter: () => { window.__enters = (window.__enters || 0) + 1; }," +
  "  onExit: () => { window.__exits = (window.__exits || 0) + 1; }" +
  "})";

async function shellInPlugin() {
  const h = await bootShell({
    plugins: [plugin("clip", "剪贴板历史", ["clip", "cb"])],
    handlers: { loadPlugin: () => ({ id: "clip", manifest: "", code: CODE, css: "" }) },
  });
  await h.search("clip abc");
  return h;
}

const shown = (h) => h.run("window.__onPanelShown()");

test("停在插件里收起面板，再呼出仍然在那个插件", async () => {
  const h = await shellInPlugin();
  try {
    assert.equal(h.get("mode"), "plugin");
    assert.equal(h.get("activePluginId"), "clip");
    assert.deepEqual(h.json("window.__queries"), ["abc"]);

    shown(h);
    assert.equal(h.get("mode"), "plugin", "不能把用户踢回搜索页");
    assert.equal(h.get("activePluginId"), "clip");
  } finally {
    h.close();
  }
});

test("再呼出时插件不会被退出、也不会重复 onEnter", async () => {
  const h = await shellInPlugin();
  try {
    shown(h);
    assert.equal(h.get("window.__exits ?? 0"), 0, "收起面板不该触发 onExit");
    assert.equal(h.get("window.__enters ?? 0"), 1, "onEnter 只在真正进入时触发一次");
  } finally {
    h.close();
  }
});

test("再呼出时重问一次插件（外部数据可能已经变了）", async () => {
  const h = await shellInPlugin();
  try {
    shown(h);
    assert.deepEqual(h.json("window.__queries"), ["abc", "abc"], "参数原样再送一次");
  } finally {
    h.close();
  }
});

test("输入框里的关键字与参数原样保留", async () => {
  const h = await shellInPlugin();
  try {
    shown(h);
    assert.equal(h.doc.getElementById("input").value, "clip abc");
  } finally {
    h.close();
  }
});

test("恢复插件时不再重设面板高度（否则会被固化成新下界）", async () => {
  const h = await shellInPlugin();
  try {
    h.stubHeight("searchbar", 52);
    h.stubHeight("results", 200);
    h.stubHeight("footer", 33);
    const before = h.calls.filter((c) => c.action === "setPanelHeight").length;
    shown(h);
    const after = h.calls.filter((c) => c.action === "setPanelHeight").length;
    assert.equal(after, before, "已在插件内，视口不该重新测量");
  } finally {
    h.close();
  }
});

test("主动按 Esc 退出后，再呼出回到搜索初始页", async () => {
  const h = await shellInPlugin();
  try {
    h.key("Escape");
    assert.equal(h.get("mode"), "search");
    assert.equal(h.get("window.__exits ?? 0"), 1, "Esc 触发一次 onExit");

    shown(h);
    assert.equal(h.get("mode"), "search");
    assert.equal(h.doc.getElementById("input").value, "", "输入框要清空");
  } finally {
    h.close();
  }
});

test("插件这期间被卸载了，就老老实实回搜索初始页", async () => {
  const h = await shellInPlugin();
  try {
    h.run("manifests = []"); // 相当于插件被删掉 / 索引重载后没了
    shown(h);
    assert.equal(h.get("mode"), "search");
    assert.equal(h.get("activePluginId"), null);
  } finally {
    h.close();
  }
});

test("在搜索态收起面板，再呼出照旧重置（不受本次改动影响）", async () => {
  const h = await bootShell({ plugins: [plugin("clip", "剪贴板历史", ["clip"])] });
  try {
    await h.search("hello");
    shown(h);
    assert.equal(h.get("mode"), "search");
    assert.equal(h.doc.getElementById("input").value, "");
  } finally {
    h.close();
  }
});
