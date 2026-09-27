// 输入框的文本编辑 + 右键菜单。
//
// 复制/粘贴/剪切/全选/撤销：快捷键交给 WebKit（见 shell.ts 里 keydown 顶部放行），
// 右键菜单自己画（WKWebView 在 macOS 上不带文本上下文菜单）。

function selectionRange(): { start: number; end: number } {
  const len = inputEl.value.length;
  return {
    start: Math.min(inputEl.selectionStart ?? len, inputEl.selectionEnd ?? len),
    end: Math.max(inputEl.selectionStart ?? len, inputEl.selectionEnd ?? len),
  };
}

function editCopy(): void {
  const { start, end } = selectionRange();
  const text = start === end ? inputEl.value : inputEl.value.slice(start, end);
  if (text) callBridge("setClipboard", { text });
}

function editCut(): void {
  const { start, end } = selectionRange();
  if (start === end) return;
  callBridge("setClipboard", { text: inputEl.value.slice(start, end) });
  inputEl.value = inputEl.value.slice(0, start) + inputEl.value.slice(end);
  inputEl.selectionStart = inputEl.selectionEnd = start;
  onInput();
}

/// 粘贴：`document.execCommand("paste")` 在 WebKit 里被安全策略禁用，
/// 所以向原生要剪贴板文本后手工插入光标处。
async function editPaste(): Promise<void> {
  const text = await callBridge("getClipboardText");
  if (typeof text !== "string" || !text) return;
  const { start, end } = selectionRange();
  inputEl.value = inputEl.value.slice(0, start) + text + inputEl.value.slice(end);
  const pos = start + text.length;
  inputEl.focus();
  inputEl.selectionStart = inputEl.selectionEnd = pos;
  onInput();
}

function editCommand(cmd: "undo" | "redo"): void {
  inputEl.focus();
  try {
    document.execCommand(cmd);
  } catch {
    return; // WebKit 不支持时静默忽略
  }
  onInput();
}

// ---- 右键菜单 ----
function closeCtxMenu(): void {
  ctxMenuEl.classList.add("hidden");
}

function openCtxMenu(x: number, y: number): void {
  const entries: { label: string; key: string; run: () => void }[] = [
    { label: t("ctxUndo"), key: "⌘Z", run: () => editCommand("undo") },
    { label: t("ctxRedo"), key: "⇧⌘Z", run: () => editCommand("redo") },
    { label: t("ctxCut"), key: "⌘X", run: editCut },
    { label: t("ctxCopy"), key: "⌘C", run: editCopy },
    { label: t("ctxPaste"), key: "⌘V", run: () => void editPaste() },
    { label: t("ctxSelectAll"), key: "⌘A", run: () => { inputEl.focus(); inputEl.select(); } },
  ];
  ctxMenuEl.innerHTML = "";
  for (const it of entries) {
    const row = document.createElement("div");
    row.className = "ctx-item";
    row.innerHTML =
      `<span>${escHtml(it.label)}</span><span class="ctx-key">${escHtml(it.key)}</span>`;
    // 阻止默认：否则 mousedown 会让输入框失焦、选区消失，剪切/复制拿到空串
    row.addEventListener("mousedown", (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
    });
    row.addEventListener("click", () => {
      closeCtxMenu();
      it.run();
    });
    ctxMenuEl.appendChild(row);
  }
  ctxMenuEl.classList.remove("hidden");

  // 贴边时往回收，别把菜单顶到面板外面
  const maxX = rootEl.clientWidth - ctxMenuEl.offsetWidth - 8;
  const maxY = rootEl.clientHeight - ctxMenuEl.offsetHeight - 8;
  ctxMenuEl.style.left = Math.max(8, Math.min(x, maxX)) + "px";
  ctxMenuEl.style.top = Math.max(8, Math.min(y, maxY)) + "px";
}

/// ←/→ 同时承担「结果导航」和「光标移动」。
/// 输入框里还有可移动空间（有选区，或光标不在两端）时让给光标，否则才导航结果。
function cursorCanMove(dir: number): boolean {
  const len = inputEl.value.length;
  const { start, end } = selectionRange();
  if (start !== end) return true; // 有选区：先让浏览器收起选区
  return dir < 0 ? start > 0 : end < len;
}
