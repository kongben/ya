#!/bin/bash
# 把 SPM 构建的二进制打包成 ya.app（含 URL scheme 注册与小黄鸭图标）
# 产物：dist/ya.app
set -e
cd "$(dirname "$0")"

APP_NAME="ya"
# SPM 资源包的命名规则是 <包名>_<target 名>.bundle：Web 资源在 library target yaCore 里
CORE_BUNDLE="ya_yaCore.bundle"
BUNDLE_ID="com.ya.app"
VERSION="0.1.0"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> 构建..."
./build.sh > /dev/null

echo "==> 生成小黄鸭 AppIcon..."
ICONSRC="$DIST/AppIcon.iconset"
rm -rf "$ICONSRC"
if [ ! -x /tmp/ya-makeicon ] || [ Sources/ya/DuckIcon.swift -nt /tmp/ya-makeicon ]; then
  swiftc -O Sources/ya/DuckIcon.swift tools/make_app_icon/main.swift -o /tmp/ya-makeicon
fi
/tmp/ya-makeicon "$ICONSRC"
iconutil -c icns "$ICONSRC" -o "$DIST/AppIcon.icns"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Web 资源直接放进 Contents/Resources/Web（AppResources 优先读这里，避免嵌套 bundle 导致签名失败）
cp -R ".build/release/${CORE_BUNDLE}/Web" "$APP/Contents/Resources/Web"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 zhouyefei. All rights reserved.</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID.urlscheme</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>yatools</string>
        <string>ya</string>
      </array>
    </dict>
  </array>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc，自用足够；分发需开发者账号公证）"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   签名失败（不影响本机运行）"

echo "==> 注册到 LaunchServices（URL scheme 生效）"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -R -f "$APP" > /dev/null 2>&1 || echo "   注册失败，可手动打开一次 .app"
fi

echo "==> 完成: $APP"
echo "    运行: open $PWD/$APP"
echo "    测试: open 'yatools://ping'（或 'ya://ping'）"
