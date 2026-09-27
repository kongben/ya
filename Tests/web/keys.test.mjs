// 键盘事件顺序
//
// 坑 23：搜索态回车执行结果后**必须** preventDefault —— 进入插件后焦点可能已经切到
//        插件自己的 textarea，这次回车的默认行为会在那里插一个换行。
// 坑 24：插件态要先让插件消费按键（**包括 ⌘/⌃ 组合**，如剪贴板的 ⌘P 收藏）；
//        「⌘/⌃ 一律放行」必须排在插件之后，否则插件快捷键永远收不到。
import test from "node:test";
import assert from "node:assert/strict";
import { bootShell, plugin } from "./harness.mjs";

test("搜索态回车：执行选中项并阻止默认行为", async () => {
  const h = await bootShell();
  try {
    h.set("items", "[{kind:'item', title:'x', action: () => { window.__ran = true; }}]");
    h.set("selected", "0");
    const e = h.key("Enter");
    assert.equal(h.window.__ran, true);
    assert.equal(e.defaultPrevented, true, "不 preventDefault 就会在插件的输入框里多一个换行");
  } finally {
    h.close();
  }
});

test("插件态：⌘ 组合键先给插件，插件处理了就阻止默认行为", async () => {
  const h = await bootShell();
  try {
    h.set("mode", "'plugin'");
    h.set("activePluginId", "'demo'");
    h.set(
      "activePlugin",
      "{ onKey: (e) => { window.__seen = e.key + (e.metaKey ? '+meta' : ''); return true; } }"
    );
    const e = h.key("p", { metaKey: true });
    assert.equal(h.window.__seen, "p+meta", "⌘P 必须能进到插件的 onKey");
    assert.equal(e.defaultPrevented, true);
  } finally {
    h.close();
  }
});

test("插件没消费的按键不再往下走（交回 AppKit / WebKit）", async () => {
  const h = await bootShell();
  try {
    h.set("mode", "'plugin'");
    h.set("activePluginId", "'demo'");
    h.set("activePlugin", "{ onKey: () => false }");
    h.set("items", "[{kind:'item', title:'x', action: () => { window.__ran = true; }}]");
    h.set("selected", "0");
    const e = h.key("Enter");
    assert.equal(h.window.__ran, undefined, "插件态的回车不该去执行搜索结果");
    assert.equal(e.defaultPrevented, false);
  } finally {
    h.close();
  }
});

test("搜索态 ⌘/⌃ 组合一律放行给系统（复制/粘贴/全选…）", async () => {
  const h = await bootShell();
  try {
    h.set("mode", "'search'");
    h.set("activePlugin", "null");
    h.set("items", "[{kind:'item', title:'x', action: () => { window.__ran = true; }}]");
    h.set("selected", "0");
    const e = h.key("c", { metaKey: true });
    assert.equal(h.window.__ran, undefined);
    assert.equal(e.defaultPrevented, false);
  } finally {
    h.close();
  }
});

test("Esc 两级：插件内先退回搜索初始页，再按一次才隐藏面板", async () => {
  const h = await bootShell();
  try {
    const input = h.doc.getElementById("input");
    h.set("mode", "'plugin'");
    h.set("activePlugin", "{ onKey: () => false }");
    input.value = "qr hello";
    h.key("Escape");
    assert.equal(h.get("mode"), "search");
    assert.equal(input.value, "");
    assert.equal(h.calls.filter((c) => c.action === "hide").length, 0, "第一次 Esc 不关面板");

    h.key("Escape"); // 已在初始页
    assert.equal(h.calls.filter((c) => c.action === "hide").length, 1);
  } finally {
    h.close();
  }
});

test("搜索态 Esc：有输入先清空，没输入才隐藏", async () => {
  const h = await bootShell();
  try {
    const input = h.doc.getElementById("input");
    input.value = "abc";
    h.key("Escape");
    assert.equal(input.value, "");
    assert.equal(h.calls.filter((c) => c.action === "hide").length, 0);
    h.key("Escape");
    assert.equal(h.calls.filter((c) => c.action === "hide").length, 1);
  } finally {
    h.close();
  }
});

test("↑↓ 在结果里移动选中项", async () => {
  const h = await bootShell();
  try {
    h.set("items", "[{kind:'item',title:'a'},{kind:'item',title:'b'},{kind:'item',title:'c'}]");
    h.run("renderResults()");
    h.set("selected", "0");
    h.key("ArrowDown");
    assert.equal(h.get("selected"), 1);
    h.key("ArrowDown");
    assert.equal(h.get("selected"), 2);
    h.key("ArrowDown"); // 到底了
    assert.equal(h.get("selected"), 2);
    h.key("ArrowUp");
    assert.equal(h.get("selected"), 1);
  } finally {
    h.close();
  }
});

test("←→ 优先让光标移动，到头了才挪选中项", async () => {
  const h = await bootShell();
  try {
    const input = h.doc.getElementById("input");
    input.value = "abc";
    input.selectionStart = input.selectionEnd = 1;
    assert.equal(h.run("cursorCanMove(1)"), true, "光标还能往右 → 让给浏览器");
    input.selectionStart = input.selectionEnd = 3;
    assert.equal(h.run("cursorCanMove(1)"), false, "光标到末尾 → 交给结果导航");
    assert.equal(h.run("cursorCanMove(-1)"), true);
    input.selectionStart = input.selectionEnd = 0;
    assert.equal(h.run("cursorCanMove(-1)"), false);
  } finally {
    h.close();
  }
});

test("Tab 进入当前选中的插件", async () => {
  const h = await bootShell({ plugins: [plugin("qrcode", "二维码", ["qr"])] });
  try {
    h.run("items = [pluginItem(manifests[0])]; selected = 0; renderResults()");
    const e = h.key("Tab");
    assert.equal(h.doc.getElementById("input").value, "qr ");
    assert.equal(e.defaultPrevented, true);
  } finally {
    h.close();
  }
});

test("进入插件就记录使用（不管有没有带参数）", async () => {
  const h = await bootShell({
    plugins: [plugin("qrcode", "二维码", ["qr"])],
    handlers: {
      // 插件代码要真的注册自己，否则 activePlugin 为 null，后面的记录/查询都不会发生
      loadPlugin: () => ({
        id: "qrcode",
        manifest: "",
        code: "window.__registerPlugin({ onQuery: () => {} })",
        css: "",
      }),
    },
  });
  try {
    await h.search("qr "); // 只有「关键字 + 空白」才进入插件
    const recorded = h.calls.filter((c) => c.action === "recordPluginUsage");
    assert.deepEqual(recorded.map((c) => c.payload.id), ["qrcode"],
      "不带参数进去也要记录，否则「最近插件」永远是那一个");
  } finally {
    h.close();
  }
});

test("输入法组合态不做插件切换（候选还没上屏）", async () => {
  const h = await bootShell({ plugins: [plugin("qrcode", "二维码", ["qr"])] });
  try {
    h.run("isComposing = true");
    assert.equal(h.run("matchPluginInput('qr ')"), null);
    h.run("isComposing = false");
    assert.ok(h.run("matchPluginInput('qr ')"), "上屏后正常进入");
  } finally {
    h.close();
  }
});
