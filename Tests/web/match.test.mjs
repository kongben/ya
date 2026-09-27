// 搜索匹配与多语言文案（Sources/ya/Web/match.ts）
import test from "node:test";
import assert from "node:assert/strict";
import { bootShell, plugin } from "./harness.mjs";

test("关键字精确 > 前缀 > 名称前缀 > 包含 > 拼音", async () => {
  const h = await bootShell();
  try {
    h.set(
      "manifests",
      JSON.stringify([
        plugin("a", "包含匹配", ["xxqrxx"]),
        plugin("b", "前缀匹配", ["qrmore"]),
        plugin("c", "精确匹配", ["qr"]),
        plugin("d", "名称前缀", ["xyz"], { name: "快速开始" }),
      ])
    );
    const order = h.json("matchPlugins('qr').map(m => m.id)");
    assert.deepEqual(order, ["c", "b", "a"], "精确(0) > 关键字前缀(1) > 关键字包含(3)");
  } finally {
    h.close();
  }
});

test("名称前缀排在关键字包含之前", async () => {
  const h = await bootShell();
  try {
    h.set(
      "manifests",
      JSON.stringify([
        plugin("a", "", ["xxqrxx"]), // 关键字包含 → 3
        plugin("b", "qrcode 工具", ["zzz"]), // 名称前缀 → 2
      ])
    );
    assert.deepEqual(h.json("matchPlugins('qr').map(m => m.id)"), ["b", "a"]);
  } finally {
    h.close();
  }
});

test("拼音首字母模糊命中", async () => {
  const h = await bootShell();
  try {
    h.set(
      "manifests",
      JSON.stringify([
        plugin("qrcode", "二维码", ["qr"], {
          pinyin: { full: "erweima", initials: "ewm" },
        }),
        plugin("other", "别的", ["other"]),
      ])
    );
    assert.deepEqual(h.json("matchPlugins('ewm').map(m => m.id)"), ["qrcode"]);
    assert.deepEqual(h.json("matchPlugins('em').map(m => m.id)"), ["qrcode"], "跳着命中也算");
    assert.deepEqual(h.json("matchPlugins('me').map(m => m.id)"), [], "顺序不对不算");
  } finally {
    h.close();
  }
});

test("兜底子串匹配至少 3 个字符", async () => {
  const h = await bootShell();
  try {
    h.set(
      "manifests",
      JSON.stringify([plugin("a", "Alpha", ["zz"], { searchText: "alpha beta" })])
    );
    assert.deepEqual(h.json("matchPlugins('bet').map(m => m.id)"), ["a"], "3 字符可兜底");
    assert.deepEqual(h.json("matchPlugins('be').map(m => m.id)"), [], "2 字符不兜底，否则刷屏");
  } finally {
    h.close();
  }
});

test("空查询返回空数组", async () => {
  const h = await bootShell({ plugins: [plugin("a", "A", ["a"])] });
  try {
    assert.deepEqual(h.json("matchPlugins('')"), []);
    assert.deepEqual(h.json("matchFeatures([], 'x')"), []);
  } finally {
    h.close();
  }
});

test("features 入口：cmd 精确 > cmd 前缀 > 标题包含", async () => {
  const h = await bootShell();
  try {
    const m = plugin("clip", "剪贴板", ["clip"], {
      features: [
        { cmd: "clear", title: "清空", titleText: "清空", keywords: ["clsclear"] },
        { cmd: "files", title: "文件", titleText: "文件", keywords: ["clsfiles"] },
        { cmd: "", title: "不可用", titleText: "不可用", keywords: [] },
      ],
    });
    h.set("manifests", JSON.stringify([m]));
    h.set("hits", "matchPlugins('clip')");
    assert.equal(h.get("hits.length"), 1);
    assert.deepEqual(h.json("matchFeatures(hits, 'clear').map(x => x.f.cmd)"), ["clear"]);
    assert.deepEqual(h.json("matchFeatures(hits, 'file').map(x => x.f.cmd)"), ["files"]);
    // 既没有 cmd 也没有可用关键字的入口（关键字全被抢占）→ 不参与匹配
    assert.deepEqual(h.json("matchFeatures(hits, '不可用').map(x => x.f.titleText)"), []);
  } finally {
    h.close();
  }
});

test("isSubsequence 边界", async () => {
  const h = await bootShell();
  try {
    assert.equal(h.run("isSubsequence('', 'abc')"), false);
    assert.equal(h.run("isSubsequence('a', '')"), false);
    assert.equal(h.run("isSubsequence('abc', 'abc')"), true);
    assert.equal(h.run("isSubsequence('ac', 'abc')"), true);
    assert.equal(h.run("isSubsequence('abcd', 'abc')"), false);
  } finally {
    h.close();
  }
});

test("loc 取当前语言，缺失时回退 en", async () => {
  const h = await bootShell({ locale: "zh" });
  try {
    assert.equal(h.run("loc({ zh: '中文', en: 'English' })"), "中文");
    h.run("lang = 'en'");
    assert.equal(h.run("loc({ zh: '中文', en: 'English' })"), "English");
    assert.equal(h.run("loc({ zh: '只有中文' })"), "", "没有 en 时返回空串而不是 undefined");
    assert.equal(h.run("loc(null)"), "");
    assert.equal(h.run("loc('纯字符串')"), "纯字符串");
  } finally {
    h.close();
  }
});

test("底部提示里的快捷键占位符会被替换", async () => {
  const h = await bootShell();
  try {
    h.run("__setHotKey('⌥ Space')");
    const text = h.doc.getElementById("footer").textContent;
    assert.ok(text.includes("⌥ Space"), `底栏文案：${text}`);
    assert.ok(!text.includes("{hk}"));
  } finally {
    h.close();
  }
});

test("非法/空的快捷键文案不生效", async () => {
  const h = await bootShell();
  try {
    const before = h.doc.getElementById("footer").textContent;
    h.run("__setHotKey('')");
    h.run("__setHotKey(123)");
    assert.equal(h.doc.getElementById("footer").textContent, before);
  } finally {
    h.close();
  }
});
