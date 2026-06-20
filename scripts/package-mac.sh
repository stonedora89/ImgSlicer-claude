#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ImgSlicer"
APP_VERSION="0.35.9"
APP_BUILD="44"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_NAME="$APP_NAME-$APP_VERSION-$APP_BUILD"
RELEASE_DIR="$DIST_DIR/$RELEASE_NAME"
APP_DIR="$RELEASE_DIR/$APP_NAME.app"
LATEST_APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ZIP_PATH="$DIST_DIR/$RELEASE_NAME.zip"
README_PATH="$RELEASE_DIR/其他Mac打开说明.txt"
INSTALLER_PATH="$RELEASE_DIR/安装.command"

cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
swift build -c debug --cache-path "$ROOT_DIR/.build/cache"
BIN_DIR="$(swift build -c debug --show-bin-path --cache-path "$ROOT_DIR/.build/cache")"

rm -rf "$RELEASE_DIR" "$LATEST_APP_DIR" "$ZIP_PATH"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN_DIR/$APP_NAME" "$MACOS/$APP_NAME"
cp "Sources/ImgSlicer/Resources/icon.svg" "$RESOURCES/icon.svg"
mkdir -p "$RESOURCES/detectors"
cp "Sources/ImgSlicer/Resources/detectors/opencv_detector.py" "$RESOURCES/detectors/opencv_detector.py"
# Bundle a self-contained, relocatable Python (with OpenCV) so the OpenCV
# detector works on any Apple Silicon Mac, even without Xcode Command Line
# Tools or Homebrew. Falls back to the local .venv only if the vendored
# runtime is missing.
if [ -d "$ROOT_DIR/vendor/python-standalone" ]; then
  ditto "$ROOT_DIR/vendor/python-standalone" "$RESOURCES/python"
elif [ -d "$ROOT_DIR/.venv" ]; then
  echo "WARNING: vendor/python-standalone missing — bundling .venv (NOT portable to other Macs)"
  ditto "$ROOT_DIR/.venv" "$RESOURCES/python"
fi
swift scripts/generate-icon.swift "$RESOURCES/AppIcon.icns" "$ROOT_DIR/Sources/ImgSlicer/Resources/icon.svg"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>ImgSlicer</string>
  <key>CFBundleIdentifier</key>
  <string>local.imgslicer.human</string>
  <key>CFBundleName</key>
  <string>ImgSlicer</string>
  <key>CFBundleDisplayName</key>
  <string>ImgSlicer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>__APP_VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__APP_BUILD__</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>ImgSlicer __APP_VERSION__</string>
</dict>
</plist>
PLIST

sed -i '' \
  -e "s/__APP_VERSION__/$APP_VERSION/g" \
  -e "s/__APP_BUILD__/$APP_BUILD/g" \
  "$CONTENTS/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
xattr -cr "$APP_DIR"

cat > "$README_PATH" <<'TXT'
ImgSlicer 其他 Mac 打开说明

如果双击提示“ImgSlicer 已损坏，无法打开”，不是文件真的损坏，而是 macOS Gatekeeper 对微信/浏览器收到的未公证应用加了隔离标记。

推荐打开方式：

1. 解压 zip。
2. 双击“安装.command”。
3. 如果系统提示不能打开脚本，请右键“安装.command”选择“打开”。
4. 安装脚本会复制 ImgSlicer.app 到“应用程序”，重新本机签名，并清除隔离属性。

手动方式：

1. 把 ImgSlicer.app 拖到“应用程序”。
2. 打开“终端”，执行：

   xattr -dr com.apple.quarantine /Applications/ImgSlicer.app

如果仍然打不开，可执行：

   codesign --force --deep --sign - /Applications/ImgSlicer.app
   xattr -dr com.apple.quarantine /Applications/ImgSlicer.app

说明：
当前版本是本地测试包，没有 Apple Developer ID 公证签名。正式商用分发需要使用 Apple Developer ID 证书签名并提交 notarization，才能像普通软件一样直接打开。
TXT

cat > "$INSTALLER_PATH" <<'SCRIPT'
#!/bin/bash
set -e

APP_NAME="ImgSlicer.app"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SOURCE_DIR/$APP_NAME"
TARGET_APP="/Applications/$APP_NAME"

if [ ! -d "$SOURCE_APP" ]; then
  echo "没有找到 $SOURCE_APP"
  read -n 1 -s -r -p "按任意键退出..."
  exit 1
fi

echo "正在安装 ImgSlicer 到 /Applications..."
rm -rf "$TARGET_APP" 2>/dev/null || true

if ! ditto "$SOURCE_APP" "$TARGET_APP" 2>/dev/null; then
  echo "需要管理员权限复制到应用程序目录。"
  sudo rm -rf "$TARGET_APP"
  sudo ditto "$SOURCE_APP" "$TARGET_APP"
fi

echo "正在修复其他 Mac 上的 Gatekeeper 隔离标记..."
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
xattr -cr "$TARGET_APP" 2>/dev/null || true

echo "正在进行本机 ad-hoc 签名..."
codesign --force --deep --sign - "$TARGET_APP"

echo "正在启动 ImgSlicer..."
open "$TARGET_APP"

echo ""
echo "安装完成。"
read -n 1 -s -r -p "按任意键关闭窗口..."
SCRIPT

chmod +x "$INSTALLER_PATH"

ditto "$APP_DIR" "$LATEST_APP_DIR"
ditto -c -k --keepParent "$RELEASE_DIR" "$ZIP_PATH"

echo "$APP_DIR"
echo "$ZIP_PATH"
