#!/bin/bash
# 跑全部单元测试：宿主前端（node:test + jsdom）+ 原生（XCTest）。
#
# 用法：
#   ./test.sh            全部
#   ./test.sh web        只跑前端（会先编译 shell.js）
#   ./test.sh swift      只跑原生
#
# 以前验证靠手写的无头 Chrome 页面临时拼（yaweb2/3/4/5…），跑完即弃、无法回归。
# 现在统一走这里：改坏了立刻红，CI/本地一个命令搞定。
set -e
cd "$(dirname "$0")"

NODE_BIN=/Users/zhouyefei/.workbuddy/binaries/node/versions/22.22.2-3/bin/node
NODE_WS=/Users/zhouyefei/.workbuddy/binaries/node/workspace
TSC="$NODE_BIN $NODE_WS/node_modules/typescript/bin/tsc"
WEB=Sources/ya/Web

run_web() {
  echo "==> 编译 TypeScript（前端单测加载的就是这份 shell.js）..."
  # 与 build.sh 完全相同的文件顺序（同作用域拼接，见 build.sh 注释）
  $TSC $WEB/bridge.ts $WEB/types.ts $WEB/match.ts $WEB/ui.ts $WEB/edit.ts $WEB/shell.ts \
    --target ES2020 --lib ES2020,DOM --outFile $WEB/shell.js
  echo "==> 前端单测（node:test + jsdom）..."
  (cd Tests/web && $NODE_BIN --test "*.test.mjs")
}

run_swift() {
  echo "==> 原生单测（XCTest）..."
  # --disable-sandbox：单测要建临时目录、跑 /usr/bin/ditto
  swift test --disable-sandbox
}

case "${1:-all}" in
  web)   run_web ;;
  swift) run_swift ;;
  all)   run_swift; run_web ;;
  *) echo "用法: $0 [all|web|swift]"; exit 1 ;;
esac

echo "==> 全部通过 ✅"
