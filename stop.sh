#!/bin/bash
# 停止 ya（含 launchd 服务）
LABEL=com.ya.agent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if launchctl print "gui/$(id -u)/$LABEL" > /dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST"
fi
pkill -f "release/ya$" 2>/dev/null
pkill -f "ya.app/Contents/MacOS/ya$" 2>/dev/null
sleep 1
if pgrep -f "release/ya$|ya.app/Contents/MacOS/ya$" > /dev/null; then
  echo "停止失败，进程仍在运行"
else
  echo "已停止"
fi
