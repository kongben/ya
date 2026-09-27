// 用 jsdom 加载**真实的** index.html + shell.js，把唯一的外部依赖（原生桥接）换成桩。
//
// 以前这类验证靠手写的无头 Chrome 页面（yaweb2/3/4/5…）临时拼，跑完就丢；
// 现在统一走 node:test，shell.js 是 build.sh 真正编译出来的那份，改坏了立刻红。
//
// 两个关键技巧：
// 1. `beforeParse` 里装桥接桩 —— 必须早于 shell.js 执行，否则 boot() 里的
//    callBridge 会撞上 undefined。
// 2. shell.js 是 `tsc --outFile` 拼出来的**普通脚本**，顶层 let/const（items / mode /
//    manifests …）进的是全局词法环境而不是 window。用 `window.eval("items")` 可以读到
//    （间接 eval 跑在全局作用域，能看到全局词法声明），写则用 `window.eval("items = X")`。

import { JSDOM } from "jsdom";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const WEB_DIR = path.resolve(HERE, "../../Sources/ya/Web");

/** 原生桥接的默认应答 */
function defaultHandlers(cfg) {
  return {
    getLocale: () => cfg.locale,
    getHotKey: () => "⌥ Space",
    listPlugins: () => cfg.plugins,
    searchApps: () => cfg.apps,
    // 应用与插件共用一条时间线：[{kind:'app',name,path} | {kind:'plugin',id}]
    getUsage: () => ({ recent: cfg.usageRecent ?? [] }),
    getIcon: () => "",
    setPanelHeight: () => null,
    hide: () => null,
    setClipboard: () => null,
    recordPluginUsage: () => null,
    recordAppUsage: () => null,
    loadPlugin: () => ({ id: "", manifest: "", code: "", css: "" }),
  };
}

function installBridge(window, cfg) {
  const calls = [];
  const handlers = { ...defaultHandlers(cfg), ...(cfg.handlers || {}) };
  window.webkit = {
    messageHandlers: {
      native: {
        postMessage(msg) {
          calls.push(msg);
          const res = handlers[msg.action] ? handlers[msg.action](msg.payload) : null;
          // id=0 是「只发不等」的高频调用（拖拽），原生不回包
          if (msg.id > 0) window.__bridgeResponse(msg.id, res);
        },
      },
    },
  };
  window.__calls = calls;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, { timeout = 3000, label = "条件" } = {}) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (fn()) return true;
    await sleep(5);
  }
  throw new Error(`等待超时：${label}`);
}

/**
 * 起一个真实的宿主外壳。
 * @returns {Promise<{dom, window, doc, calls, set, get, run, waitFor, close}>}
 */
export async function bootShell(cfg = {}) {
  const options = {
    locale: cfg.locale ?? "zh",
    plugins: cfg.plugins ?? [],
    apps: cfg.apps ?? [],
    usageRecent: cfg.usageRecent ?? [],
    handlers: cfg.handlers ?? {},
  };

  const dom = await JSDOM.fromFile(path.join(WEB_DIR, "index.html"), {
    runScripts: "dangerously",
    resources: "usable",
    pretendToBeVisual: true,
    beforeParse(window) {
      installBridge(window, options);
    },
  });
  const { window } = dom;

  // 等 boot() 跑完：它 await 了 getLocale / listPlugins，最后调 showUsage()
  await waitFor(() => window.eval("typeof items !== 'undefined' && items.length > 0"), {
    label: "boot() 完成（items 被填充）",
  });

  const api = {
    dom,
    window,
    doc: window.document,
    calls: window.__calls,
    /** 读脚本作用域里的变量：get("items") */
    get: (expr) => window.eval(expr),
    /** 写脚本作用域里的变量：set("mode", "'plugin'")（传的是源码文本） */
    set: (name, srcExpr) => window.eval(`${name} = ${srcExpr}`),
    /** 在脚本作用域里执行一段代码 */
    run: (src) => window.eval(src),
    /**
     * 取值并转成 Node 侧的普通对象再返回。
     * 必须走 JSON：jsdom 里的 Array/Object 原型属于另一个 realm，
     * 直接 deepEqual 会因为原型不同而判不相等（哪怕内容一样）。
     */
    json: (src) => JSON.parse(JSON.stringify(window.eval(src))),
    waitFor,
    sleep,
    /** 按下某键（宿主在 document 上监听 keydown） */
    key(key, init = {}) {
      const e = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
      window.document.dispatchEvent(e);
      return e;
    },
    /** 输入框打字（走防抖，需要 await sleep(200) 或直接调 onInput） */
    type(text) {
      const input = window.document.getElementById("input");
      input.value = text;
      input.dispatchEvent(new window.Event("input", { bubbles: true }));
    },
    /** 立刻执行查询，不等防抖 */
    async search(text) {
      const input = window.document.getElementById("input");
      input.value = text;
      await window.eval("onInput()");
      await sleep(10);
    },
    /** 让元素有真实高度（jsdom 的 offsetHeight 恒为 0，面板高度算不出来） */
    stubHeight(id, px) {
      const el = window.document.getElementById(id);
      Object.defineProperty(el, "offsetHeight", { value: px, configurable: true });
      return el;
    },
    /** 结果区的标题文本（分组名 + 条目名） */
    resultTexts() {
      return [...window.document.querySelectorAll("#results li")]
        .map((li) => li.textContent.trim());
    },
    close() { dom.window.close(); },
  };
  return api;
}

/** 造一个插件清单（字段对齐原生 listPlugins 的输出） */
export function plugin(id, name, keywords, extra = {}) {
  return {
    id,
    name,
    keyword: keywords[0] ?? "",
    keywords,
    declaredKeywords: keywords,
    conflictWith: "",
    activateKeyword: keywords[0] ?? "",
    iconKey: `plugin:${id}`,
    searchText: `${name} ${keywords.join(" ")} ${id}`.toLowerCase(),
    pinyin: { full: "", initials: "" },
    features: [],
    ...extra,
  };
}
