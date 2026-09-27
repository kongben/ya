#!/bin/bash
# 构建 ya：先编译 TS，再 swift build
set -e
cd "$(dirname "$0")"

NODE_BIN=/Users/zhouyefei/.workbuddy/binaries/node/versions/22.22.2-3/bin/node
NODE_WS=/Users/zhouyefei/.workbuddy/binaries/node/workspace
TSC="$NODE_BIN $NODE_WS/node_modules/typescript/bin/tsc"
WEB=Sources/ya/Web

echo "==> 编译 TypeScript..."
# 顺序即拼接顺序：types 只有类型声明；match 定义 lang 与 t；
# ui / edit 的函数都在运行时才被调用，所以可以排在定义状态的 shell.ts 之前
$TSC $WEB/bridge.ts $WEB/types.ts $WEB/match.ts $WEB/ui.ts $WEB/edit.ts $WEB/shell.ts \
  --target ES2020 --lib ES2020,DOM --outFile $WEB/shell.js
# 注：宿主不再内置任何插件（原 calculator / clipboard 已移出为独立插件工程，
# 见 ~/Desktop/ya-plugin）。内置插件目录 Web/plugins/ 已删除，这里无需再编译插件 TS。

echo "==> swift build..."
swift build -c release --disable-sandbox

echo "==> 构建完成: .build/release/ya"
