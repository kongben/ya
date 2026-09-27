// 先确认 harness 本身能用：jsdom 能加载真实 shell.js、能读到脚本作用域的变量。
import test from "node:test";
import assert from "node:assert/strict";
import { bootShell, plugin } from "./harness.mjs";

// 白屏兜底靠这两个标记：原生加载完成后查 __yaScriptLoaded，没置位就重载一次。
// 它们一旦被误删，"shell.js 语法错误 → 全白面板 → 用户只会说点了没反应"就又没人知道了。
test("脚本执行完要置位就绪标记（白屏兜底依赖）", async () => {
  const h = await bootShell();
  try {
    assert.equal(
      h.get("window.__yaScriptLoaded"),
      true,
      "脚本跑到末尾就要置位，原生靠它判断是不是白屏"
    );
    // __yaBooted 依赖桥接，harness 里桥接是桩，boot() 能跑完就说明置位了
    assert.equal(h.get("window.__yaBooted"), true);
  } finally {
    h.close();
  }
});

test("shell.js 能在 jsdom 里启动并完成 boot()", async () => {
  const h = await bootShell({
    plugins: [plugin("qrcode", "二维码", ["qr"])],
    usageRecent: [{ kind: "plugin", id: "qrcode" }],
  });
  try {
    assert.equal(h.get("lang"), "zh");
    assert.equal(h.get("manifests.length"), 1);
    assert.ok(h.get("items.length") > 0, "初始页要有内容");
    assert.ok(h.calls.some((c) => c.action === "listPlugins"));
    assert.ok(h.calls.some((c) => c.action === "getUsage"));
    assert.equal(h.doc.getElementById("input").placeholder.includes("搜索"), true);
  } finally {
    h.close();
  }
});
