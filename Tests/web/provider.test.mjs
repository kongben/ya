// 结果提供者（provider）机制：plugin.json 声明 `"provider": true` 的插件，
// 不靠关键字触发，而是宿主每次搜索都把输入原文交给它的 onProvide，结果并进主列表。
//
// 这组测试只验**宿主机制**（调度、护栏、渲染），识别逻辑本身在 smart 插件那边验。
import test from "node:test";
import assert from "node:assert/strict";
import { bootShell, plugin } from "./harness.mjs";

/** 造一个 provider 插件的代码：onProvide 返回固定结果（或按 opts 出现异常/永不返回） */
function providerCode(id, items, opts = {}) {
  const body = opts.hang
    ? "return new Promise(() => {});" // 永不 resolve，用来验超时
    : opts.throw
      ? "throw new Error('boom');"
      : opts.async
        ? `return Promise.resolve(${JSON.stringify(items)});`
        : `return ${JSON.stringify(items)};`;
  return `
    window.__provideCalls = window.__provideCalls || {};
    window.__registerPlugin({
      onQuery: function () {},
      onProvide: function (q, api) {
        window.__provideCalls['${id}'] = (window.__provideCalls['${id}'] || 0) + 1;
        if (api && api.db) api.db.setItem('k', 'v');
        ${body}
      },
    });
  `;
}

function providerManifest(id, opts = {}) {
  return plugin(id, opts.name || id, opts.keywords ?? [], {
    provider: true,
    ...opts.extra,
  });
}

test("provider 结果插在主列表最前面", async () => {
  const h = await bootShell({
    plugins: [providerManifest("sm", { name: "识别" })],
    apps: [{ name: "WeChat", path: "/Applications/WeChat.app" }],
    handlers: {
      loadPlugin: () => ({
        id: "sm",
        manifest: "",
        code: providerCode("sm", [{ title: "2024-01-01", subtitle: "时间戳转日期" }]),
        css: "",
      }),
    },
  });
  try {
    await h.search("1700000000");
    await h.waitFor(() => h.resultTexts().some((t) => t.includes("2024-01-01")), {
      label: "provider 条目出现",
    });
    const texts = h.resultTexts();
    const smartAt = texts.indexOf("智能识别");
    const appsAt = texts.indexOf("应用");
    assert.ok(smartAt >= 0, `缺少智能识别分组：${JSON.stringify(texts)}`);
    assert.ok(appsAt >= 0, "缺少应用分组");
    assert.ok(smartAt < appsAt, "provider 结果必须排在应用之前");
    assert.ok(
      texts.some((t) => t.includes("2024-01-01")),
      `provider 条目没渲染出来：${JSON.stringify(texts)} / items=${JSON.stringify(h.json("items"))}`
    );
  } finally {
    h.close();
  }
});

test("provider 结果带插件图标与色块", async () => {
  const h = await bootShell({
    plugins: [providerManifest("sm")],
    handlers: {
      loadPlugin: () => ({
        id: "sm",
        manifest: "",
        code: providerCode("sm", [{ title: "#ff8800", subtitle: "rgb(255, 136, 0)", swatch: "#ff8800" }]),
        css: "",
      }),
    },
  });
  try {
    await h.search("#ff8800");
    await h.waitFor(() => h.json("items.filter(i => i.kind === 'item').length") > 0, {
      label: "provider 条目出现",
    });
    const items = h.json("items.filter(i => i.kind === 'item')");
    assert.equal(items.length, 1);
    assert.equal(items[0].iconKey, "plugin:sm", "图标用插件自己的");
    assert.equal(items[0].swatch, "#ff8800");
    assert.equal(items[0].pluginId, "sm");
  } finally {
    h.close();
  }
});

test("单个 provider 最多贡献 3 条，不会淹没应用搜索", async () => {
  const many = Array.from({ length: 8 }, (_, i) => ({ title: `r${i}`, subtitle: "s" }));
  const h = await bootShell({
    plugins: [providerManifest("sm")],
    handlers: {
      loadPlugin: () => ({
        id: "sm",
        manifest: "",
        code: providerCode("sm", many),
        css: "",
      }),
    },
  });
  try {
    await h.search("123456");
    await h.waitFor(() => h.json("items.filter(i => i.kind === 'item').length") === 3, {
      label: "3 条上限生效",
    });
    assert.equal(h.json("items.filter(i => i.kind === 'item').length"), 3);
  } finally {
    h.close();
  }
});

test("多个 provider 的结果按 manifests 顺序拼，不随机", async () => {
  const h = await bootShell({
    plugins: [providerManifest("a"), providerManifest("b")],
    handlers: {
      loadPlugin: (p) => ({
        id: p.id,
        manifest: "",
        // b 走异步 Promise，验证结果顺序不会因为完成时间先后而乱
        code: providerCode(p.id, [{ title: `from-${p.id}`, subtitle: "s" }], {
          async: p.id === "b",
        }),
        css: "",
      }),
    },
  });
  try {
    await h.search("xyz");
    await h.waitFor(() => h.json("items.filter(i => i.kind === 'item').length") === 2, {
      label: "两个 provider 都出结果",
    });
    const titles = h.json("items.filter(i => i.kind === 'item').map(i => i.title)");
    assert.deepEqual(titles, ["from-a", "from-b"], `顺序应为 manifests 顺序：${titles}`);
  } finally {
    h.close();
  }
});

test("provider 卡住时 300ms 超时，输入不会被拖死", async () => {
  const h = await bootShell({
    plugins: [providerManifest("slow")],
    apps: [{ name: "WeChat", path: "/Applications/WeChat.app" }],
    handlers: {
      loadPlugin: () => ({
        id: "slow",
        manifest: "",
        code: providerCode("slow", [], { hang: true }),
        css: "",
      }),
    },
  });
  try {
    const t0 = Date.now();
    await h.search("hello");
    await h.waitFor(() => h.resultTexts().includes("应用"), { label: "应用结果出现", timeout: 2000 });
    const spent = Date.now() - t0;
    assert.ok(spent < 1500, `超时保护应该让结果在 1.5s 内出来，实际 ${spent}ms`);
    assert.ok(!h.resultTexts().includes("智能识别"), "卡住的 provider 不该留下空分组");
  } finally {
    h.close();
  }
});

test("provider 抛异常会被停用，后续击键不再问它", async () => {
  const h = await bootShell({
    plugins: [providerManifest("bad")],
    handlers: {
      loadPlugin: () => ({
        id: "bad",
        manifest: "",
        code: providerCode("bad", [], { throw: true }),
        css: "",
      }),
    },
  });
  try {
    await h.search("aaaa");
    await h.waitFor(() => !!h.json("window.__provideCalls"), { label: "provider 被调用过" });
    await h.search("bbbb");
    await h.sleep(120);
    const calls = h.json("window.__provideCalls");
    assert.equal(calls.bad, 1, `只该被问一次，实际 ${calls.bad} 次 —— 停用没生效`);
  } finally {
    h.close();
  }
});

test("provider 的存储走插件自己的命名空间（不是 global）", async () => {
  const h = await bootShell({
    plugins: [providerManifest("sm")],
    handlers: {
      loadPlugin: () => ({
        id: "sm",
        manifest: "",
        code: providerCode("sm", [{ title: "x", subtitle: "s" }]),
        css: "",
      }),
    },
  });
  try {
    await h.search("123456");
    await h.waitFor(() => h.calls.some((c) => c.action === "dbSet"), { label: "provider 写过存储" });
    const dbSet = h.calls.filter((c) => c.action === "dbSet");
    assert.ok(dbSet.length > 0, "provider 应该能写自己的存储");
    for (const c of dbSet) {
      assert.equal(c.payload.plugin, "sm", `存储必须隔离到插件：${JSON.stringify(c.payload)}`);
    }
  } finally {
    h.close();
  }
});

test("没有关键字的 provider 不会出现在「我的插件」里（点进去也没东西）", async () => {
  const h = await bootShell({
    plugins: [providerManifest("sm", { name: "识别" }), plugin("clip", "剪贴板", ["clip"])],
  });
  try {
    const titles = h.json("items.filter(i => i.kind === 'item').map(i => i.title)");
    assert.ok(!titles.includes("识别"), `无关键字的 provider 不该作为插件卡片：${titles}`);
    assert.ok(titles.includes("剪贴板"));
  } finally {
    h.close();
  }
});

test("provider 同时有关键字时，两边都能用（双入口）", async () => {
  const h = await bootShell({
    plugins: [providerManifest("sm", { name: "识别", keywords: ["s", "smart"] })],
    handlers: {
      loadPlugin: () => ({
        id: "sm",
        manifest: "",
        code: providerCode("sm", [{ title: "识别出结果", subtitle: "s" }]),
        css: "",
      }),
    },
  });
  try {
    // ① 免关键字：搜索正文里出现它的结果
    await h.search("1700000000");
    await h.waitFor(() => h.resultTexts().some((t) => t.includes("识别出结果")), {
      label: "免关键字通道出结果",
    });
    // ② 显式进入：关键字 + 空格进插件模式
    await h.search("s 1700000000");
    await h.waitFor(() => h.get("mode") === "plugin", { label: "显式进入插件模式" });
    assert.equal(h.get("mode"), "plugin");
    assert.equal(h.get("activePluginId"), "sm");
  } finally {
    h.close();
  }
});
