__registerPlugin({
    onQuery(arg, container) {
        const zh = typeof __lang === "function" && __lang() === "zh";
        if (!arg.trim()) {
            container.innerHTML = `<div class="hi-empty">${zh ? "随便输入点什么，我会回显它" : "Type something, I'll echo it"}</div>`;
            return;
        }
        container.innerHTML =
            `<div class="hi-echo">${arg}</div>` +
                `<div class="hi-hint">${zh ? "Enter 复制到剪贴板" : "Enter to copy"}</div>`;
    },
    onKey(e) {
        const el = document.querySelector(".hi-echo");
        if (e.key === "Enter" && el && el.textContent) {
            callBridge("setClipboard", { text: el.textContent });
            callBridge("hide");
            return true;
        }
        return false;
    },
});
