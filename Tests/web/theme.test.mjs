// 深浅色主题
//
// 面板是 WKWebView 画的，配色全靠 CSS 的 prefers-color-scheme：
// - 深色写在外层 :root（默认），浅色在同一批变量名上覆盖；
// - 手动切换不改 CSS，由原生设置 NSApp.appearance（见 Theme.swift），
//   所以**样式表只有一份**，不存在 data-theme 覆盖块。
//
// 这里守住两条最容易翻车的规则：
// 1. 浅色块必须覆盖深色块里的**每一个**颜色变量 —— 漏一个，它在浅色下就还是深色的值
//    （典型是浅底浅字，直接看不见，而且很难看出是漏了变量）。
// 2. 调色板之外不许再写颜色字面量 —— 写死一处，换主题时那块永远停在深色。
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { WEB_DIR } from "./harness.mjs";

const CSS = fs.readFileSync(path.join(WEB_DIR, "shell.css"), "utf8");
const HTML = fs.readFileSync(path.join(WEB_DIR, "index.html"), "utf8");

/** 与主题无关的变量：两套配色共用，浅色块里不用重复定义 */
const THEME_INDEPENDENT = ["--ya-radius", "--ya-font"];

function paletteBody(re) {
  const m = CSS.match(re);
  assert.ok(m, `shell.css 里没找到调色板：${re}`);
  return m[1];
}

function varNames(body) {
  return [...body.matchAll(/(--ya-[a-z-]+)\s*:/g)].map((m) => m[1]);
}

const darkBody = paletteBody(/:root\s*\{([\s\S]*?)\}/);
const lightBody = paletteBody(
  /@media \(prefers-color-scheme: light\)\s*\{[\s\S]*?:root\s*\{([\s\S]*?)\}/
);

test("浅色块覆盖了深色块的每一个颜色变量", () => {
  const dark = varNames(darkBody).filter((v) => !THEME_INDEPENDENT.includes(v));
  const light = new Set(varNames(lightBody));
  const missing = dark.filter((v) => !light.has(v));
  assert.deepEqual(
    missing,
    [],
    `这些变量在浅色下会沿用深色值（浅底浅字 = 看不见）：${missing.join(", ")}`
  );
  assert.ok(dark.length >= 15, "变量太少，多半是正则没匹配上");
});

test("两套配色都声明了 color-scheme（决定原生滚动条明暗）", () => {
  assert.match(darkBody, /color-scheme:\s*dark/);
  assert.match(lightBody, /color-scheme:\s*light/);
});

test("调色板之外不许再写颜色字面量", () => {
  const COLOR = /#[0-9a-fA-F]{3,8}\b|rgba?\(/;
  const bad = [];
  let inPalette = false;
  CSS.split("\n").forEach((line, i) => {
    const t = line.trim();
    if (t.startsWith("}")) { inPalette = false; return; }
    if (t.startsWith(":root") || t.startsWith("@media")) { inPalette = true; return; }
    if (t.startsWith("/*") || t.startsWith("*")) return;
    if (!inPalette && COLOR.test(line)) bad.push(`${i + 1}: ${t}`);
  });
  assert.deepEqual(bad, [], "换主题时这些块不会跟着变");
});

test("index.html 声明支持两套配色", () => {
  assert.match(HTML, /name="color-scheme"\s+content="light dark"/);
});
