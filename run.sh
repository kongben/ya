#!/bin/bash
# 启动 ya（优先使用 dist/ya.app —— 只有 .app 才注册了 yatools:// 协议）
# 用 os.setsid 建立独立会话/进程组，使应用彻底脱离启动它的终端，
# 不会被任何会话清理（SIGHUP / 进程组 kill）误杀
cd "$(dirname "$0")"

if [ -x "$(pwd)/dist/ya.app/Contents/MacOS/ya" ]; then
  BIN="$(pwd)/dist/ya.app/Contents/MacOS/ya"
else
  BIN="$(pwd)/.build/release/ya"
fi
if [ ! -x "$BIN" ]; then
  echo "尚未构建，先执行 ./build.sh（或 ./package.sh 打包出 ya.app）"
  exit 1
fi

BIN_NAME="$(basename "$BIN")"
if pgrep -f "MacOS/$BIN_NAME$|release/$BIN_NAME$" > /dev/null; then
  echo "ya 已在运行"
  exit 0
fi

/usr/bin/python3 - "$BIN" <<'PY'
import os, subprocess, sys, time
bin_path = sys.argv[1]
log = open("/tmp/ya.log", "ab", buffering=0)
err = open("/tmp/ya.err", "ab", buffering=0)
subprocess.Popen([bin_path],
                 stdin=subprocess.DEVNULL,
                 stdout=log, stderr=err,
                 start_new_session=True,   # setsid：独立会话，免疫进程组 kill
                 close_fds=True)
time.sleep(1.2)
PY

sleep 1
if pgrep -f "MacOS/$BIN_NAME$|release/$BIN_NAME$" > /dev/null; then
  echo "ya 已启动（独立会话 PID $(pgrep -f "MacOS/$BIN_NAME$|release/$BIN_NAME$")），按 Option+Space 呼出"
else
  echo "启动失败，日志：/tmp/ya.err"
  tail -5 /tmp/ya.err 2>/dev/null
fi
