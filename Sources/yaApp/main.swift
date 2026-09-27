// 可执行文件入口：只做一件事 —— 把控制权交给 yaCore。
// 启动过程在 AppBootstrap 里（那边才能访问 internal 的 AppDelegate）。
import yaCore

AppBootstrap.run()
