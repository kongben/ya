// 示例用户插件：关键字 hi，回显输入内容
// 演示插件自带样式：class 用 .hi-* ，样式写在同目录 style.css（宿主会自动注入并加作用域）
declare const __registerPlugin: (p: any) => void;
declare const callBridge: (action: string, payload?: any) => Promise<any>;
declare const __lang: () => string;

__registerPlugin({
  onQuery(arg: string, container: HTMLElement) {
    const zh = typeof __lang === "function" && __lang() === "zh";
    if (!arg.trim()) {
      container.innerHTML = `<div class="hi-empty">${
        zh ? "随便输入点什么，我会回显它" : "Type something, I'll echo it"
      }</div>`;
      return;
    }
    container.innerHTML =
      `<div class="hi-echo">${arg}</div>` +
      `<div class="hi-hint">${zh ? "Enter 复制到剪贴板" : "Enter to copy"}</div>`;
  },
  onKey(e: KeyboardEvent): boolean {
    const el = document.querySelector(".hi-echo");
    if (e.key === "Enter" && el && el.textContent) {
      callBridge("setClipboard", { text: el.textContent });
      callBridge("hide");
      return true;
    }
    return false;
  },
});
