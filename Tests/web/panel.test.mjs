// 面板高度与面板拖拽
//
// 坑 26：setExpendHeight 的语义是「插件内容区要多少 px」，外壳（搜索栏 + 底栏 + 余量）
//        由宿主补。插件以前得自己猜外壳多高，猜少一点内容就被挤出滚动条。
// 坑 25：mousedown 里 preventDefault 会把随后的 click 一起吞掉，插件里「点一行就复制」
//        这类交互会全部失灵。
// 坑 28：拖拽只上报鼠标的**屏幕坐标**，窗口位置由原生按锚点算。用 clientX 算增量会因为
//        「窗口一动 clientX 就反向变一次」形成正反馈，面板来回抖。
import test from "node:test";
import assert from "node:assert/strict";
import { bootShell, plugin } from "./harness.mjs";

const CODE = "window.__registerPlugin({ onQuery: () => {}, onEnter: () => {}, onExit: () => {} })";

const lastCall = (h, action) => [...h.calls].reverse().find((c) => c.action === action);
const callsOf = (h, action) => h.calls.filter((c) => c.action === action);

// 坑 38：插件视图的高度由宿主统一拍板，不交给插件自己 clamp。
//        每个插件各写一套封顶（qrcode 900 / smart 520 / urlc 各一个常量）的结果是
//        「搜索 → 插件」切换时窗口换一档尺寸，在插件里每敲一个字又换一档 —— 看着就是页面在闪。
//        统一口径：视口下界 = 刚离开的那份搜索结果的高度（切换前后总高不变），上界 = 560 面板封顶，
//        中间的平凡变化用 40px 滞后吃掉，超过上界就在 #pluginView 里滚动。
//
// jsdom 里 offsetHeight 恒为 0，用 stubHeight 造出真实外壳尺寸再算高度。
function stubChrome(h) {
  h.stubHeight("searchbar", 52);
  h.stubHeight("footer", 33);
}

/// 走一遍「搜索态 → 进入插件」：搜索结果 200px（面板 301），再切进插件
function enterPlugin(h) {
  stubChrome(h);
  h.stubHeight("results", 200);
  h.run("mode = 'search'; lastPanelHeight = 0; autoHeight()");
  h.run("capturePanelViewport(); setMode('plugin'); beginPluginViewport()");
}

test("setExpendHeight 只算内容高度，外壳由宿主补", async () => {
  const h = await bootShell();
  try {
    stubChrome(h);
    h.run("setMode('plugin')"); // 插件态搜索栏离屏，不计入外壳
    assert.equal(h.get("panelChromeHeight()"), 49, "底栏 33 + 余量 16");

    h.run("api.setExpendHeight(400)");
    assert.equal(lastCall(h, "setPanelHeight").payload.height, 449, "400 内容 + 49 外壳");
  } finally {
    h.close();
  }
});

test("插件要了输入框时，搜索栏高度计入外壳", async () => {
  const h = await bootShell();
  try {
    stubChrome(h);
    h.run("setMode('plugin')");
    h.run("api.showInput('输入点什么')"); // 显式要求保留输入框
    assert.equal(h.get("panelChromeHeight()"), 101, "搜索栏 52 + 底栏 33 + 余量 16");
    h.run("api.setExpendHeight(400)");
    assert.equal(lastCall(h, "setPanelHeight").payload.height, 501);
  } finally {
    h.close();
  }
});

test("顶部拖拽条的 12px 要计入面板高度（否则底栏被挤出滚动条）", async () => {
  const h = await bootShell();
  try {
    const bar = h.doc.getElementById("dragbar");
    assert.ok(bar, "index.html 里要有 #dragbar");
    assert.equal(
      h.doc.getElementById("root").firstElementChild.id,
      "dragbar",
      "拖拽条必须在搜索栏之前（它是「输入框上面那一点点区域」）"
    );

    stubChrome(h);
    h.stubHeight("dragbar", 12);
    h.run("setMode('plugin')");
    assert.equal(h.get("panelChromeHeight()"), 61, "拖拽条 12 + 底栏 33 + 余量 16");

    h.stubHeight("results", 200);
    h.run("setMode('search')");
    h.run("lastPanelHeight = 0");
    h.run("autoHeight()");
    assert.equal(lastCall(h, "setPanelHeight").payload.height, 313, "12 + 52 + 200 + 33 + 16");
  } finally {
    h.close();
  }
});

test("搜索态 autoHeight 与 setExpendHeight 用同一口径", async () => {
  const h = await bootShell();
  try {
    stubChrome(h);
    h.stubHeight("results", 200);
    h.run("setMode('search')");
    h.run("lastPanelHeight = 0");
    h.run("autoHeight()");
    assert.equal(lastCall(h, "setPanelHeight").payload.height, 301, "52 + 200 + 33 + 16");
  } finally {
    h.close();
  }
});

test("高度变化小于 40px 就不上报，避免每敲一个字母都抖", async () => {
  const h = await bootShell();
  try {
    stubChrome(h);
    h.stubHeight("results", 200);
    h.run("setMode('search')");
    h.run("lastPanelHeight = 290"); // 与 301 只差 11
    const before = callsOf(h, "setPanelHeight").length;
    h.run("autoHeight()");
    assert.equal(callsOf(h, "setPanelHeight").length, before, "滞后区内不重复上报");
  } finally {
    h.close();
  }
});

test("进入插件时面板总高不变（插件顶替搜索结果的位置）", async () => {
  const h = await bootShell();
  try {
    enterPlugin(h);
    // 301 = 搜索态总高；插件态外壳矮了 52（搜索栏离屏），这 52 全部让给内容区
    assert.equal(lastCall(h, "setPanelHeight").payload.height, 301);
    assert.equal(h.get("pluginViewportHeight"), 252, "301 − 49 外壳");
    const view = h.doc.getElementById("pluginView");
    assert.equal(view.style.minHeight, "252px");
    assert.equal(view.style.maxHeight, "252px", "min=max：超出就滚动，不顶高面板");
  } finally {
    h.close();
  }
});

test("插件内容比搜索结果矮时不会被压缩（补到下界）", async () => {
  const h = await bootShell();
  try {
    enterPlugin(h);
    h.run("api.setExpendHeight(80)");
    assert.equal(h.get("pluginViewportHeight"), 252, "矮内容不能让面板缩一下");
    assert.equal(lastCall(h, "setPanelHeight").payload.height, 301);
  } finally {
    h.close();
  }
});

test("内容超过上限就不再长高，改由容器滚动", async () => {
  const h = await bootShell();
  try {
    enterPlugin(h);
    h.run("api.setExpendHeight(900)");
    assert.equal(h.get("pluginViewportHeight"), 511, "560 面板封顶 − 49 外壳");
    assert.equal(lastCall(h, "setPanelHeight").payload.height, 560, "与搜索态同一个封顶");
    assert.equal(h.doc.getElementById("pluginView").style.maxHeight, "511px");
  } finally {
    h.close();
  }
});

test("插件高度小幅摇摆不上报（40px 滞后）", async () => {
  const h = await bootShell();
  try {
    enterPlugin(h);
    h.run("api.setExpendHeight(300)");
    const n = callsOf(h, "setPanelHeight").length;
    h.run("api.setExpendHeight(320)"); // 只比 300 矮一点
    assert.equal(callsOf(h, "setPanelHeight").length, n, "摇摆不该让窗口跟着抖");
    h.run("api.setExpendHeight(360)"); // 超过阈值才动
    assert.equal(callsOf(h, "setPanelHeight").length, n + 1);
  } finally {
    h.close();
  }
});

test("换插件用同一套边界，不继承上一个插件的高度", async () => {
  const h = await bootShell();
  try {
    enterPlugin(h);
    h.run("api.setExpendHeight(500)");
    assert.equal(h.get("pluginViewportHeight"), 500);

    // 退出再进：视口回到下界，而不是停在 500
    h.run("exitPlugin(); setMode('search'); autoHeight()");
    enterPlugin(h);
    assert.equal(h.get("pluginViewportHeight"), 252, "每个插件的起点都是搜索结果的高度");
  } finally {
    h.close();
  }
});

test("退出插件后，搜索态重新按结果测高（不被插件高度卡住）", async () => {
  const h = await bootShell();
  try {
    enterPlugin(h);
    h.run("api.setExpendHeight(500)");
    h.run("exitPlugin()");
    h.run("autoHeight()");
    assert.equal(
      lastCall(h, "setPanelHeight").payload.height,
      301,
      "清掉 lastPanelHeight，否则滞后区会把搜索态卡在插件的高度上"
    );
    assert.equal(h.doc.getElementById("pluginView").style.maxHeight, "", "尺寸补丁要撤干净");
  } finally {
    h.close();
  }
});

test("插件内继续打字不会把当前高度固化成下界（否则面板只增不减）", async () => {
  const h = await bootShell({
    plugins: [plugin("clip", "剪贴板历史", ["clip"])],
    handlers: { loadPlugin: () => ({ id: "clip", manifest: "", code: CODE, css: "" }) },
  });
  try {
    stubChrome(h);
    h.stubHeight("results", 200);
    await h.search("cl"); // 搜索态：面板 301
    await h.search("clip "); // 进插件：视口 252
    assert.equal(h.get("pluginViewportHeight"), 252);

    h.run("api.setExpendHeight(400)"); // 内容变多
    await h.search("clip abc"); // 继续打字
    assert.equal(h.get("pluginViewportHeight"), 400, "插件内的输入不该重设下界");

    h.run("api.setExpendHeight(300)"); // 内容又变少
    assert.equal(h.get("pluginViewportHeight"), 300, "要能缩得回去");
  } finally {
    h.close();
  }
});

test("没测过搜索态高度时（面板刚呼出）进插件有兜底", async () => {
  const h = await bootShell();
  try {
    stubChrome(h);
    h.run("lastPanelHeight = 0; capturePanelViewport(); setMode('plugin'); beginPluginViewport()");
    assert.equal(h.get("pluginViewportHeight"), 240, "绝对下界");
    assert.equal(lastCall(h, "setPanelHeight").payload.height, 289);
  } finally {
    h.close();
  }
});

// ---- 拖拽 ----

function mouse(h, type, x, y, target) {
  const el = target ?? h.window;
  const e = new h.window.MouseEvent(type, {
    button: 0,
    screenX: x,
    screenY: y,
    clientX: x,
    clientY: y,
    bubbles: true,
    cancelable: true,
  });
  el.dispatchEvent(e);
  return e;
}

test("拖拽只上报屏幕坐标，且高频调用不等回包（id=0）", async () => {
  const h = await bootShell();
  try {
    const root = h.doc.getElementById("root");
    mouse(h, "mousedown", 100, 200, root);
    mouse(h, "mousemove", 150, 180);
    await h.sleep(60); // 等 rAF 合并的那一帧
    mouse(h, "mouseup", 150, 180);

    const begin = lastCall(h, "beginPanelDrag");
    assert.deepEqual([begin.payload.x, begin.payload.y], [100, 200], "锚点 = 按下时的屏幕坐标");

    const move = callsOf(h, "movePanel");
    assert.ok(move.length >= 1);
    // 报的是**绝对屏幕坐标**，不是「这次移动了多少」
    assert.deepEqual([move.at(-1).payload.x, move.at(-1).payload.y], [150, 180]);
    assert.ok(move.every((c) => c.id === 0), "movePanel 必须走 postBridge（id=0，不回包）");

    assert.equal(callsOf(h, "endPanelDrag").length, 1, "松手才落盘，中途不写 UserDefaults");
  } finally {
    h.close();
  }
});

test("移动不到阈值（4px）不算拖拽", async () => {
  const h = await bootShell();
  try {
    const root = h.doc.getElementById("root");
    mouse(h, "mousedown", 100, 200, root);
    mouse(h, "mousemove", 102, 201);
    await h.sleep(60);
    mouse(h, "mouseup", 102, 201);
    assert.equal(callsOf(h, "movePanel").length, 0);
    assert.equal(callsOf(h, "endPanelDrag").length, 0);
  } finally {
    h.close();
  }
});

test("mousedown 不能 preventDefault（否则插件里的点击交互全废）", async () => {
  const h = await bootShell();
  try {
    const root = h.doc.getElementById("root");
    const e = mouse(h, "mousedown", 100, 200, root);
    assert.equal(e.defaultPrevented, false);
  } finally {
    h.close();
  }
});

test("拖完的那一次 click 要被吃掉，避免误执行刚拖过的条目", async () => {
  const h = await bootShell();
  try {
    const root = h.doc.getElementById("root");
    mouse(h, "mousedown", 100, 200, root);
    mouse(h, "mousemove", 160, 240);
    await h.sleep(60);
    mouse(h, "mouseup", 160, 240);

    const click = new h.window.MouseEvent("click", { bubbles: true, cancelable: true });
    root.dispatchEvent(click);
    assert.equal(click.defaultPrevented, true);
  } finally {
    h.close();
  }
});

test("没拖动 = 普通点击，不能被吃掉", async () => {
  const h = await bootShell();
  try {
    const root = h.doc.getElementById("root");
    mouse(h, "mousedown", 100, 200, root);
    mouse(h, "mouseup", 100, 200);
    const click = new h.window.MouseEvent("click", { bubbles: true, cancelable: true });
    root.dispatchEvent(click);
    assert.equal(click.defaultPrevented, false);
  } finally {
    h.close();
  }
});

test("拖拽条上按下不用等阈值：动 1px 就开始拖", async () => {
  const h = await bootShell();
  try {
    const bar = h.doc.getElementById("dragbar");
    mouse(h, "mousedown", 100, 200, bar);
    mouse(h, "mousemove", 101, 200); // 只动了 1px，低于普通区域的 4px 阈值
    await h.sleep(60); // 等 rAF 合并的那一帧
    mouse(h, "mouseup", 101, 200);

    assert.equal(callsOf(h, "beginPanelDrag").length, 1);
    assert.ok(callsOf(h, "movePanel").length >= 1, "专用拖拽条上按下就是要拖");
    assert.equal(callsOf(h, "endPanelDrag").length, 1, "松手落盘");
  } finally {
    h.close();
  }
});

test("拖拖拽条时抓手高亮，松手恢复", async () => {
  const h = await bootShell();
  try {
    const bar = h.doc.getElementById("dragbar");
    mouse(h, "mousedown", 100, 200, bar);
    assert.equal(bar.classList.contains("dragging"), false, "光按下不算在拖");
    mouse(h, "mousemove", 140, 230);
    await h.sleep(60);
    assert.equal(bar.classList.contains("dragging"), true);
    mouse(h, "mouseup", 140, 230);
    assert.equal(bar.classList.contains("dragging"), false);
  } finally {
    h.close();
  }
});

test("拖拽条之外仍要走 4px 阈值（避免拖过面板就误移动）", async () => {
  const h = await bootShell();
  try {
    const root = h.doc.getElementById("root");
    // 点在底栏上：属于面板空白处，但不在拖拽条上
    mouse(h, "mousedown", 100, 200, h.doc.getElementById("footer"));
    mouse(h, "mousemove", 101, 200);
    await h.sleep(60);
    mouse(h, "mouseup", 101, 200);
    assert.equal(callsOf(h, "movePanel").length, 0, "1px 抖动不该把面板挪走");
  } finally {
    h.close();
  }
});

test("输入框 / 结果项 / 右键菜单上按下不触发拖拽", async () => {
  const h = await bootShell({ plugins: [] });
  try {
    h.run("items = [{kind:'item', title:'x'}]; renderResults()");
    const li = h.doc.querySelector("#results li");
    mouse(h, "mousedown", 100, 200, li);
    assert.equal(callsOf(h, "beginPanelDrag").length, 0, "结果项是拿来点的");

    mouse(h, "mousedown", 100, 200, h.doc.getElementById("input"));
    assert.equal(callsOf(h, "beginPanelDrag").length, 0, "输入框要能拖选文本");
  } finally {
    h.close();
  }
});

test("没拖动时把焦点还给输入框，否则后面敲的字全丢", async () => {
  const h = await bootShell();
  try {
    const input = h.doc.getElementById("input");
    input.focus();
    h.doc.body.focus(); // 模拟「点到了不可聚焦区域」
    const root = h.doc.getElementById("root");
    mouse(h, "mousedown", 100, 200, root);
    mouse(h, "mouseup", 100, 200);
    assert.equal(h.doc.activeElement.id, "input");
  } finally {
    h.close();
  }
});
