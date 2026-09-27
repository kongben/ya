// 渲染层（Sources/ya/Web/ui.ts）：HTML 转义、插件 CSS 作用域、二维布局、右键菜单
import test from "node:test";
import assert from "node:assert/strict";
import { bootShell } from "./harness.mjs";

test("escHtml 挡住 HTML 注入", async () => {
  const h = await bootShell();
  try {
    assert.equal(h.run(`escHtml('<img src=x onerror=alert(1)>')`),
      "&lt;img src=x onerror=alert(1)&gt;");
    assert.equal(h.run(`escHtml('a"b\\'c&d')`), "a&quot;b&#39;c&amp;d");
  } finally {
    h.close();
  }
});

test("插件名里的非法字符要换成 -，才能当 class 用", async () => {
  const h = await bootShell();
  try {
    assert.equal(h.run("pluginScopeClass('qr code')"), "ya-plugin-qr-code");
    assert.equal(h.run("pluginScopeClass('a.b/c')"), "ya-plugin-a-b-c");
  } finally {
    h.close();
  }
});

test("scopeSelector：页面级选择器映射到容器自身，其余加前缀", async () => {
  const h = await bootShell();
  try {
    const s = (sel) => h.run(`scopeSelector(${JSON.stringify(sel)}, 'ya-plugin-demo')`);
    assert.equal(s("body"), ".ya-plugin-demo");
    assert.equal(s(":root"), ".ya-plugin-demo");
    assert.equal(s("html"), ".ya-plugin-demo");
    assert.equal(s("#pluginView"), ".ya-plugin-demo", "插件给根容器设样式要用这条");
    assert.equal(s("div"), ".ya-plugin-demo div");
    assert.equal(s(".item-title"), ".ya-plugin-demo .item-title");
    assert.equal(s("a, b"), ".ya-plugin-demo a, .ya-plugin-demo b", "逗号分隔的每一项都要加");
  } finally {
    h.close();
  }
});

test("注入插件 CSS 会加作用域前缀，重复注入不留旧样式", async () => {
  const h = await bootShell();
  try {
    h.run(`injectPluginCss('demo', '.a{color:red} body{margin:0} @media screen{.b{color:blue}}')`);
    const first = h.doc.getElementById("ya-plugin-css-demo");
    assert.ok(first, "style 标签要带 id，才能卸载");

    const selectors = [...first.sheet.cssRules].map((r) => r.selectorText ?? `[${r.cssText.slice(0, 20)}]`);
    assert.equal(selectors[0], ".ya-plugin-demo .a", "普通选择器加前缀，否则会污染宿主");
    assert.equal(selectors[1], ".ya-plugin-demo", "body 映射到插件容器自身");
    assert.ok(
      [...first.sheet.cssRules[2].cssRules].some((r) => r.selectorText === ".ya-plugin-demo .b"),
      "@media 里的规则也要递归加前缀"
    );

    h.run(`injectPluginCss('demo', '.c{color:blue}')`);
    assert.equal(h.doc.querySelectorAll("#ya-plugin-css-demo").length, 1, "重复注入要先移除旧的");
  } finally {
    h.close();
  }
});

test("空的 CSS 不注入", async () => {
  const h = await bootShell();
  try {
    h.run(`injectPluginCss('demo', '')`);
    assert.equal(h.doc.getElementById("ya-plugin-css-demo"), null);
  } finally {
    h.close();
  }
});

test("二维布局：网格一行 6 个，列表项独占一行", async () => {
  const h = await bootShell();
  try {
    h.set(
      "items",
      JSON.stringify([
        { kind: "header", title: "G" },
        ...Array.from({ length: 7 }, (_, i) => ({ kind: "item", title: `c${i}`, grid: true })),
        { kind: "item", title: "row" },
      ])
    );
    h.run("buildLayout()");
    const layout = h.json("[...layout.entries()].map(([i, p]) => [i, p.row, p.col])");
    // 下标 0 是分组标题（独占一行，不进 layout）
    assert.deepEqual(layout[0], [1, 1, 0], "第一个卡片在第 1 行第 0 列");
    assert.deepEqual(layout[5], [6, 1, 5]);
    assert.deepEqual(layout[6], [7, 2, 0], "第 7 个换行到第 2 行");
    assert.deepEqual(layout[7], [8, 3, 0], "列表项独占一行");
  } finally {
    h.close();
  }
});

test("↑↓ 跨行时会跳过空的分组标题行", async () => {
  const h = await bootShell();
  try {
    h.set(
      "items",
      JSON.stringify([
        { kind: "header", title: "A" },
        { kind: "item", title: "a1", grid: true },
        { kind: "header", title: "B" },
        { kind: "item", title: "b1", grid: true },
      ])
    );
    h.run("renderResults()");
    h.set("selected", "1");
    h.run("moveSelection(1)");
    assert.equal(h.json("items[selected].title"), "b1", "标题行是空的，会被跳过");
    h.run("moveSelection(-1)");
    assert.equal(h.json("items[selected].title"), "a1");
  } finally {
    h.close();
  }
});

test("→ 走到行尾就不动了", async () => {
  const h = await bootShell();
  try {
    h.set(
      "items",
      JSON.stringify([{ kind: "item", title: "a", grid: true }, { kind: "item", title: "b", grid: true }])
    );
    h.run("renderResults()");
    h.set("selected", "1");
    h.run("moveSelection(1, true)");
    assert.equal(h.get("selected"), 1, "越界不移动");
  } finally {
    h.close();
  }
});

test("图标按 iconKey 定位，不靠行号（列表重排也不会填错行）", async () => {
  const h = await bootShell();
  try {
    h.set(
      "items",
      JSON.stringify([
        { kind: "item", title: "a", iconKey: "app:/A.app" },
        { kind: "item", title: "b", iconKey: "app:/B.app" },
      ])
    );
    h.run("renderResults()");
    const dots = [...h.doc.querySelectorAll("#results .dot")];
    assert.deepEqual(dots.map((d) => d.getAttribute("data-icon-for")), ["app:/A.app", "app:/B.app"]);

    // 原生推送图标：只有对应 key 的占位符被替换
    h.run(`__iconReady('app:/B.app', 'AAAA')`);
    const imgs = [...h.doc.querySelectorAll("#results img")];
    assert.equal(imgs.length, 1);
    assert.ok(imgs[0].src.includes("AAAA"));
    assert.equal(
      h.doc.querySelector('#results [data-icon-for="app:/A.app"]') !== null,
      true,
      "A 的占位符还在"
    );
  } finally {
    h.close();
  }
});

test("右键菜单：打开 → 点条目 → 关闭", async () => {
  const h = await bootShell();
  try {
    const input = h.doc.getElementById("input");
    const menu = h.doc.getElementById("ctxMenu");
    input.value = "hello";
    const ev = new h.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 20 });
    input.dispatchEvent(ev);
    assert.equal(ev.defaultPrevented, true, "要自己画菜单，不能用系统菜单");
    assert.equal(menu.classList.contains("hidden"), false);
    assert.equal(menu.querySelectorAll(".ctx-item").length, 6);

    // 点「复制」：菜单关闭，且不报错（剪贴板走桥接）
    menu.querySelectorAll(".ctx-item")[3].dispatchEvent(new h.window.MouseEvent("click", { bubbles: true }));
    assert.equal(menu.classList.contains("hidden"), true);
  } finally {
    h.close();
  }
});

test("结果项里的特殊字符不会破坏 DOM", async () => {
  const h = await bootShell();
  try {
    h.set("items", JSON.stringify([{ kind: "item", title: "<b>x</b>", subtitle: "a & b" }]));
    h.run("renderResults()");
    const li = h.doc.querySelector("#results li");
    assert.equal(li.querySelectorAll("b").length, 0, "标签要被转义，不能真的插进去");
    assert.ok(li.textContent.includes("<b>x</b>"));
  } finally {
    h.close();
  }
});
