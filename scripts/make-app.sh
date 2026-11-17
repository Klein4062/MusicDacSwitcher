#!/bin/zsh
# make-app.sh — 构建 MusicDacSwitcher.app（菜单栏图形界面）
# 用法: ./scripts/make-app.sh [--install]
#   --install  构建后复制到 /Applications

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MusicDacSwitcher"
APP="build/${APP_NAME}.app"

echo "▸ 编译（release）…"
swift build -c release --product MDSBar

echo "▸ 生成图标…"
if [[ ! -f build/AppIcon.icns ]]; then
    swift scripts/gen-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

echo "▸ 组装 .app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MDSBar "$APP/Contents/MacOS/${APP_NAME}"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>MusicDacSwitcher</string>
    <key>CFBundleDisplayName</key>       <string>MusicDacSwitcher</string>
    <key>CFBundleIdentifier</key>        <string>com.musicdacswitcher.app</string>
    <key>CFBundleExecutable</key>        <string>MusicDacSwitcher</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSUIElement</key>               <true/>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ ad-hoc 签名…"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  （跳过签名）"

if [[ "${1:-}" == "--install" ]]; then
    echo "▸ 安装到 /Applications…"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" "/Applications/"
    echo "✅ 已安装: /Applications/${APP_NAME}.app"
    echo "   启动: open /Applications/${APP_NAME}.app"
else
    echo "✅ $APP"
    echo "   启动: open $APP"
fi
