// 宿主前端的公共类型。
//
// build.sh 用 `tsc --outFile` 把 bridge / smart / types / match / ui / edit / shell
// 合成一个 shell.js，所以它们**同属一个全局作用域**（见 agent.md 坑 15）：
// 这里只放类型声明，不放运行时代码，避免顶层 const/let 与别的文件撞名。

/// 插件清单（原生 listPlugins 推来的形态）
interface PluginManifest {
  id: string;
  name: any; // string 或 { en, zh }
  keyword: string; // 有效主关键字（被抢占时为空串）
  keywords: string[]; // 有效关键字（主关键字 + 未被抢占的别名）
  declaredKeywords: string[]; // 插件声明的全部关键字
  conflictWith: string; // 抢占者插件 id，空串表示无冲突
  activateKeyword: string; // 进入插件时实际使用的关键字
  iconKey: string;
  searchText: string;
  pinyin: { full: string; initials: string };
  description?: any;
  source?: string;
  features?: PluginFeature[]; // plugin.json 的 features[]：插件的额外入口
  input?: string; // plugin.json 的 input："visible" = 进入插件后保留输入框
  provider?: boolean; // plugin.json 的 provider：true = 结果提供者（不靠关键字触发）
}

/// 插件的一个入口。`cmd` 为空串表示主入口（没写 features 的老插件只有主入口）
interface PluginFeature {
  cmd: string;
  title: any;
  titleText: string;
  keywords: string[];
}

/// 传给插件的「当前功能」上下文
interface PluginFeatureContext {
  cmd: string; // features[].cmd，主入口为 ""
  title: string; // 当前语言的显示名，主入口为插件名
}

type Lang = "en" | "zh";

interface PluginAPI {
  // 通用
  callBridge: (action: string, payload?: any) => Promise<any>;
  esc: (s: string) => string;
  lang: () => Lang;
  // 窗口
  hide: () => void;
  show: () => void;
  setExpendHeight: (height: number) => void;
  setSubInput: (handler: (text: string) => void, placeholder?: string) => void;
  setSubInputValue: (text: string) => void;
  removeSubInput: () => void;
  // 宿主输入框：进插件后默认收起（交互交给插件），需要输入的插件可再要回来
  showInput: (placeholder?: string) => void;
  hideInput: () => void;
  // 系统
  notice: (body: string) => void;
  openPath: (path: string) => void;
  openURL: (url: string) => void;
  showInFinder: (path: string) => void;
  trashItem: (path: string) => void;
  beep: () => void;
  getPath: (name: string) => Promise<string>;
  getFileIcon: (pathOrExt: string) => Promise<string>;
  getNativeId: () => Promise<string>;
  getAppInfo: () => Promise<{ name: string; version: string }>;
  isDarkColors: () => Promise<boolean>;
  assetUrl: (name: string) => Promise<string>; // 插件自带资源 → data URL
  // 剪贴板
  copyText: (text: string) => void;
  getClipboardText: () => Promise<string>;
  getCopiedFiles: () => Promise<any[]>;
  getClipboardHistory: () => Promise<ClipHistoryEntry[]>;
  // 剪贴板历史（结构化：文本 / 图片 / 文件）
  clipboard: {
    history: () => Promise<ClipHistoryEntry[]>;
    image: (id: string) => Promise<string>; // 缩略图 data URL
    copy: (id: string) => Promise<boolean>; // 把某条写回系统剪贴板
    pin: (id: string) => Promise<any>; // 收藏 / 取消收藏
    remove: (id: string) => Promise<any>;
    clear: (includingPinned?: boolean) => Promise<any>;
  };
  // 存储
  db: {
    getItem: (key: string) => Promise<string>;
    setItem: (key: string, value: string) => Promise<any>;
    removeItem: (key: string) => Promise<any>;
  };
}

/// 剪贴板历史条目（文本 / 图片 / 文件）
interface ClipHistoryEntry {
  id: string;
  kind: "text" | "image" | "file";
  text: string; // 文本内容；file 类型为换行拼接的路径
  paths: string[]; // 文件路径（仅 file 类型）
  timestamp: number; // 秒级时间戳
  pinned: boolean;
  hasImage: boolean; // 有缩略图时可取 api.clipboard.image(id)
}

interface ResultItem {
  kind: "header" | "item";
  title?: string;
  subtitle?: string;
  iconKey?: string; // 图标缓存键："app:<路径>" / "plugin:<id>"
  pluginId?: string;
  grid?: boolean; // true = 渲染成方形卡片（一行多个），false = 整行列表项
  action?: () => void;
  swatch?: string; // 左侧小色块（万能输入框的颜色识别用）
}

/// 结果提供者（`provider: true`）往宿主主结果列表里贡献的一条结果。
///
/// 与「接管面板型」插件的区别：这一条由宿主渲染、宿主负责键盘导航与回车执行，
/// 插件只给出「显示什么」和「做什么」，不碰 DOM。
interface ProviderItem {
  title: string;
  subtitle?: string;
  /// 回车要复制的文本（不填 action 时的默认动作）
  copy?: string;
  /// 回车要打开的链接（有值时同时打开与复制，与旧版万能输入框一致）
  openURL?: string;
  /// 左侧小色块（CSS 颜色值，颜色识别用）
  swatch?: string;
  /// 完全自定义动作；给了它就忽略 copy / openURL，且不自动收起面板
  action?: () => void;
}

interface PluginInstance {
  onQuery: (arg: string, container: HTMLElement, api: PluginAPI, feature?: PluginFeatureContext) => void;
  onKey?: (e: KeyboardEvent, container: HTMLElement, api: PluginAPI) => boolean;
  onEnter?: (api: PluginAPI) => void; // 进入插件时触发一次
  onExit?: () => void; // 离开插件 / 面板隐藏时触发
  onFeature?: (feature: PluginFeatureContext, api: PluginAPI) => void; // 切换入口时触发

  /// 结果提供者专用：宿主每次搜索都把输入原文交给它，它返回要插进主列表的结果。
  ///
  /// 这是**每次击键都会跑**的用户代码，宿主有三道护栏（见 shell.ts 的 collectProviderItems）：
  /// 单次超时、抛异常即本次会话禁用、单插件结果条数上限。
  /// 必须同步返回或返回 Promise；返回空数组表示"这次没我的事"。
  onProvide?: (
    query: string,
    api: PluginAPI
  ) => ProviderItem[] | Promise<ProviderItem[]>;
}
