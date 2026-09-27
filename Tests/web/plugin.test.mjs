// 插件调度与插件 API（Sources/ya/Web/shell.ts）
import test from "node:test";
import assert from "node:assert/strict";
import { bootShell, plugin } from "./harness.mjs";

const CODE = "window.__registerPlugin({ onQuery: () => {}, onEnter: () => {}, onExit: () => {} })";

function shellWithPlugin(features = []) {
  return bootShell({
    plugins: [plugin("clip", "剪贴板历史", ["clip", "cb"], { features })],
    handlers: {
      loadPlugin: () => ({ id: "clip", manifest: "", code: CODE, css: ".x{color:red}" }),
    },
  });
}

test("关键字 + 空白才进入插件（只敲关键字时它只是搜索结果）", async () => {
  const h = await shellWithPlugin();
  try {
    assert.equal(h.run("matchPluginInput('clip')"), null);
    const hit = h.run("matchPluginInput('clip abc')");
    assert.ok(hit);
    assert.equal(hit.m.id, "clip");
    assert.equal(hit.arg, "abc");
  } finally {
    h.close();
  }
});

test("别名也能进插件", async () => {
  const h = await shellWithPlugin();
  try {
    assert.equal(h.run("matchPluginInput('cb x')").m.id, "clip");
  } finally {
    h.close();
  }
});

test("features：首 token 命中 cmd 时切成对应入口", async () => {
  const h = await shellWithPlugin([
    { cmd: "clear", title: "清空", titleText: "清空", keywords: ["clsclear"] },
  ]);
  try {
    const r = h.run("matchPluginInput('clip clear abc')");
    assert.equal(r.cmd, "clear");
    assert.equal(r.arg, "abc", "命令本身要从参数里剥掉");
    // 不是 cmd 的首 token 原样交给主入口
    assert.equal(h.run("matchPluginInput('clip hello')").cmd, "");
  } finally {
    h.close();
  }
});

test("feature 专属关键字直通（不用先敲插件主关键字）", async () => {
  const h = await shellWithPlugin([
    { cmd: "clear", title: "清空", titleText: "清空", keywords: ["clsclear"] },
  ]);
  try {
    const r = h.run("matchPluginInput('clsclear abc')");
    assert.equal(r.m.id, "clip");
    assert.equal(r.cmd, "clear");
  } finally {
    h.close();
  }
});

test("进入插件后只要输入仍以关键字开头就留在插件内", async () => {
  const h = await shellWithPlugin();
  try {
    h.set("activePluginId", "'clip'");
    assert.ok(h.run("matchPluginInput('clip')"), "光秃秃的关键字也算，别把用户踢回搜索");
    assert.equal(h.run("matchPluginInput('other x')"), null, "换了关键字就退出");
  } finally {
    h.close();
  }
});

test("进入插件会加载代码、注入 CSS、触发 onEnter", async () => {
  const h = await shellWithPlugin();
  try {
    await h.search("clip hello");
    assert.equal(h.get("mode"), "plugin");
    assert.equal(h.get("activePluginId"), "clip");
    assert.ok(h.calls.some((c) => c.action === "loadPlugin" && c.payload.id === "clip"));
    assert.ok(h.doc.getElementById("ya-plugin-css-clip"), "插件 CSS 要注入");
  } finally {
    h.close();
  }
});

test("切换入口只通知一次 onFeature", async () => {
  const h = await shellWithPlugin([
    { cmd: "clear", title: "清空", titleText: "清空", keywords: ["clsclear"] },
    { cmd: "files", title: "文件", titleText: "文件", keywords: ["clsfiles"] },
  ]);
  try {
    let features = [];
    h.set(
      "activePlugin",
      "{ onQuery: () => {}, onFeature: (ctx) => { window.__features = (window.__features||[]).concat(ctx.cmd); } }"
    );
    h.set("loadedPlugins", "new Map([['clip', activePlugin]])");
    h.set("activePluginId", "'clip'");
    await h.search("clip clear");
    await h.search("clip clear x");
    await h.search("clip files");
    features = h.json("window.__features || []");
    assert.deepEqual(features, ["clear", "files"], "同一个入口重复调用不该重复通知");
  } finally {
    h.close();
  }
});

test("退出插件会清状态并调 onExit", async () => {
  const h = await shellWithPlugin();
  try {
    let exited = false;
    h.set("activePlugin", "{ onQuery: () => {}, onExit: () => { window.__exited = true; } }");
    h.set("loadedPlugins", "new Map([['clip', activePlugin]])");
    h.set("activePluginId", "'clip'");
    h.set("activePluginKeyword", "'clip'");
    h.set("mode", "'plugin'");
    h.run("exitPlugin()");
    exited = h.get("window.__exited");
    assert.equal(exited, true);
    assert.equal(h.get("activePluginId"), null);
    assert.equal(h.get("mode"), "search");
    assert.equal(
      h.doc.getElementById("pluginView").classList.contains("ya-plugin-clip"),
      false,
      "作用域 class 要一起摘掉"
    );
  } finally {
    h.close();
  }
});

test("插件存储按插件隔离，不在插件内时落到 global", async () => {
  const h = await bootShell();
  try {
    h.set("activePluginId", "null");
    h.run("api.db.setItem('k', 'v')");
    assert.equal(h.calls.at(-1).payload.plugin, "global");

    h.set("activePluginId", "'clip'");
    h.run("api.db.setItem('k', 'v')");
    assert.equal(h.calls.at(-1).payload.plugin, "clip", "插件之间不能互相看到");
  } finally {
    h.close();
  }
});

test("插件声明 input:visible 时保留输入框", async () => {
  const h = await bootShell({
    plugins: [plugin("calc", "计算器", ["calc"], { input: "visible" })],
  });
  try {
    h.set("activePluginId", "'calc'");
    h.set("mode", "'plugin'");
    h.run("updateInputVisibility()");
    assert.equal(h.doc.getElementById("searchbar").classList.contains("off"), false);
  } finally {
    h.close();
  }
});

test("默认收起输入框，但插件调 showInput 会放出来", async () => {
  const h = await bootShell({ plugins: [plugin("qrcode", "二维码", ["qr"])] });
  try {
    h.set("activePluginId", "'qrcode'");
    h.run("setMode('plugin')");
    assert.equal(h.doc.getElementById("searchbar").classList.contains("off"), true);
    h.run("api.showInput()");
    assert.equal(h.doc.getElementById("searchbar").classList.contains("off"), false);
    h.run("api.hideInput()");
    assert.equal(h.doc.getElementById("searchbar").classList.contains("off"), true);
  } finally {
    h.close();
  }
});

test("setSubInputValue 会把关键字一起回填到输入框", async () => {
  const h = await bootShell();
  try {
    h.set("activePluginKeyword", "'clip'");
    h.run("api.setSubInputValue('abc')");
    assert.equal(h.doc.getElementById("input").value, "clip abc");
  } finally {
    h.close();
  }
});

test("插件加载失败不影响宿主（不会白屏）", async () => {
  const h = await bootShell({
    plugins: [plugin("bad", "坏插件", ["bad"])],
    handlers: { loadPlugin: () => ({ id: "bad", manifest: "", code: "throw new Error('boom')", css: "" }) },
  });
  try {
    await h.search("bad x");
    assert.equal(h.get("activePluginId"), "bad", "宿主状态照常推进");
    assert.equal(h.get("activePlugin"), null, "没注册成功就不算加载过");
  } finally {
    h.close();
  }
});
