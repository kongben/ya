// JS <-> Swift 原生桥接
let __cbId = 0;
const __callbacks = new Map<number, (data: any) => void>();

(window as any).__bridgeResponse = (id: number, data: any) => {
  const cb = __callbacks.get(id);
  if (cb) {
    __callbacks.delete(id);
    cb(data);
  }
};

// 原生未响应时的兜底超时，避免 promise 永久 pending（调用方也拿不到结果）
const BRIDGE_TIMEOUT_MS = 10000;

function callBridge(action: string, payload: any = {}): Promise<any> {
  return new Promise((resolve) => {
    const id = ++__cbId;
    let settled = false;
    const done = (data: any) => {
      if (settled) return;
      settled = true;
      __callbacks.delete(id);
      resolve(data);
    };
    __callbacks.set(id, done);
    setTimeout(() => {
      if (!settled) {
        console.warn("[ya] bridge timeout:", action);
        done(null);
      }
    }, BRIDGE_TIMEOUT_MS);
    (window as any).webkit.messageHandlers.native.postMessage({ id, action, payload });
  });
}

/// 只发不等：id 传 0，原生不再 evaluateJavaScript 回包。
/// 拖拽这类每秒几十次的高频调用必须走这里——否则每次回包都要过一次主线程，窗口会一卡一卡的。
function postBridge(action: string, payload: any = {}): void {
  (window as any).webkit.messageHandlers.native.postMessage({ id: 0, action, payload });
}
