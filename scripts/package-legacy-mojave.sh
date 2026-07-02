#!/usr/bin/env bash
set -euo pipefail

# Packages the full-featured legacy AppKit UI (FionaSpotterTool) against the
# CURRENT detection sources in Sources/ImgSlicer, so algorithm work flows into
# the Mojave build without maintaining a frozen copy. Ported from
# hasselblad/项目源码/scripts/package-legacy-mojave.sh (0.35.2-39), plus the
# Core ML segmenter the current pipeline needs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DISPLAY_NAME="FionaSpotterTool"
EXECUTABLE_NAME="fiona-spotter-tool"
APP_VERSION="0.35.12"
APP_BUILD="40"
RELEASE_BASE_NAME="$APP_DISPLAY_NAME-Mojave-Intel-$APP_VERSION-$APP_BUILD"
RELEASE_NAME="$RELEASE_BASE_NAME"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/.build/legacy-mojave"

cd "$ROOT_DIR"
mkdir -p "$DIST_DIR" "$BUILD_DIR"
if [ -e "$DIST_DIR/$RELEASE_NAME" ] || [ -e "$DIST_DIR/$RELEASE_NAME.dmg" ]; then
  suffix=2
  while [ -e "$DIST_DIR/$RELEASE_BASE_NAME $suffix" ] || [ -e "$DIST_DIR/$RELEASE_BASE_NAME $suffix.dmg" ]; do
    suffix=$((suffix + 1))
  done
  RELEASE_NAME="$RELEASE_BASE_NAME $suffix"
fi

RELEASE_DIR="$DIST_DIR/$RELEASE_NAME"
APP_DIR="$RELEASE_DIR/$APP_DISPLAY_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
EXECUTABLE="$MACOS/$EXECUTABLE_NAME"
REAL_EXECUTABLE="$MACOS/$EXECUTABLE_NAME-bin"
INTEL_EXECUTABLE="$MACOS/$EXECUTABLE_NAME-bin-x86_64"
ARM_EXECUTABLE="$MACOS/$EXECUTABLE_NAME-bin-arm64"
DMG_PATH="$DIST_DIR/$RELEASE_NAME.dmg"
README_PATH="$RELEASE_DIR/其他Mac打开说明.txt"
CHANGELOG_PATH="$RELEASE_DIR/版本更新说明.txt"
INSTALLER_PATH="$RELEASE_DIR/安装.command"
DIAGNOSTIC_PATH="$RELEASE_DIR/启动诊断.command"

mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS" "$RESOURCES/detectors"
cp "Sources/ImgSlicer/Resources/detectors/opencv_detector.py" "$RESOURCES/detectors/opencv_detector.py"

SOURCES=(
  "Sources/ImgSlicerLegacy/main.swift"
  "Sources/ImgSlicer/Models.swift"
  "Sources/ImgSlicer/FolderScanner.swift"
  "Sources/ImgSlicer/ExternalDetector.swift"
  "Sources/ImgSlicer/ImageLoading.swift"
  "Sources/ImgSlicer/ImageProcessor.swift"
  "Sources/ImgSlicer/NeuralSegmenter.swift"
  "Sources/ImgSlicer/Processing/CropDetectionPipeline.swift"
  "Sources/ImgSlicer/Processing/CropEditStore.swift"
  "Sources/ImgSlicer/Processing/SampleLibrary.swift"
)

build_slice() {
  local target="$1" output="$2"
  CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" swiftc \
    -swift-version 5 \
    -D IMGSLICER_MOJAVE \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -target "$target" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -O \
    -framework AppKit \
    -framework ImageIO \
    -framework CoreGraphics \
    -framework Vision \
    -framework CoreML \
    "${SOURCES[@]}" \
    -o "$output"
}

build_slice "x86_64-apple-macosx10.14" "$INTEL_EXECUTABLE"
# Apple Silicon did not exist on Mojave. The arm64 slice therefore targets the
# first macOS release that supports it, while the Intel slice remains Mojave.
build_slice "arm64-apple-macosx11.0" "$ARM_EXECUTABLE"

lipo -create "$INTEL_EXECUTABLE" "$ARM_EXECUTABLE" -output "$REAL_EXECUTABLE"
rm -f "$INTEL_EXECUTABLE" "$ARM_EXECUTABLE"

cat > "$EXECUTABLE" <<'SCRIPT'
#!/bin/bash

LOG="$HOME/Desktop/fiona-spotter-tool-mojave-launcher.log"
APP_MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_CONTENTS_DIR="$(cd "$APP_MACOS_DIR/.." && pwd)"
REAL_EXECUTABLE="$APP_MACOS_DIR/fiona-spotter-tool-bin"
FRAMEWORKS_DIR="$APP_CONTENTS_DIR/Frameworks"

if [ -d "$FRAMEWORKS_DIR" ]; then
  rm -f "$FRAMEWORKS_DIR"/libswift*.dylib 2>/dev/null || true
fi

{
  echo "Launcher started: $(date)"
  echo "macOS: $(sw_vers -productVersion 2>/dev/null || true)"
  echo "Executable: $REAL_EXECUTABLE"
  echo "Contents: $APP_CONTENTS_DIR"
  echo "Running app binary..."
} >> "$LOG" 2>&1

exec "$REAL_EXECUTABLE" "$@" >> "$LOG" 2>&1
SCRIPT

chmod +x "$EXECUTABLE"

# Core ML segmenter for the hybrid "no black border" trim. If 10.14's Core ML
# can't load it the detector falls back to the pure-heuristic box.
if [ -d "Sources/ImgSlicer/MLModel/PhotoSegmenter.mlmodelc" ]; then
  ditto "Sources/ImgSlicer/MLModel/PhotoSegmenter.mlmodelc" "$RESOURCES/PhotoSegmenter.mlmodelc"
else
  echo "WARNING: PhotoSegmenter.mlmodelc missing; build will run heuristic-only (black borders kept)" >&2
fi

cp "Sources/ImgSlicer/Resources/AppIconSource.png" "$RESOURCES/AppIconSource.png"
if ! swift scripts/generate-icon.swift "$RESOURCES/AppIcon.icns" "$ROOT_DIR/Sources/ImgSlicer/Resources/AppIconSource.png"; then
  echo "WARNING: 无法生成 AppIcon.icns，将使用系统默认图标。" >&2
  rm -f "$RESOURCES/AppIcon.icns"
fi

ICON_KEY=""
if [ -f "$RESOURCES/AppIcon.icns" ]; then
  ICON_KEY="  <key>CFBundleIconFile</key>
  <string>AppIcon</string>"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.fiona.spotter.tool.legacy</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
$ICON_KEY
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.14</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

install_name_tool -delete_rpath "@executable_path/../Frameworks" "$REAL_EXECUTABLE" 2>/dev/null || true
install_name_tool -add_rpath /usr/lib/swift "$REAL_EXECUTABLE" 2>/dev/null || true

cat > "$README_PATH" <<'TXT'
FionaSpotterTool Mojave Intel 打开说明

这个包用于 macOS 10.14.6 Mojave Intel 电脑。

推荐打开方式：

1. 打开 DMG。
2. 双击“安装.command”。
3. 如果系统提示不能打开脚本，请右键“安装.command”选择“打开”。
4. 脚本会复制 FionaSpotterTool.app 到“应用程序”，重新本机签名，并清除 Gatekeeper 隔离标记。

如果双击 app 提示“已损坏”或“无法验证开发者”，通常不是文件损坏，而是未公证测试包被 macOS 加了隔离标记。

手动修复：

   xattr -dr com.apple.quarantine "/Applications/FionaSpotterTool.app"
   codesign --force --deep --sign - "/Applications/FionaSpotterTool.app"

说明：
当前是本地测试包，没有 Apple Developer ID 公证签名。正式分发需要 Apple Developer ID 签名并 notarize。
TXT

cat > "$CHANGELOG_PATH" <<TXT
$APP_DISPLAY_NAME Mojave Intel $APP_VERSION-$APP_BUILD 版本更新说明

打包文件：
- 文件夹：$RELEASE_NAME
- 应用：$APP_DISPLAY_NAME.app
- DMG：$RELEASE_NAME.dmg

本次更新（算法整体升级到 0.35.12 主线）：
- 识别算法不再使用打包时的旧副本，改为与主线 ImgSlicer 相同的最新检测管线，
  包含自适应沟槽检测、跨列画幅拆分、暗画幅碎片合并、倾斜校正等改进。
- 新增混合神经网络去黑边：识别红框的上下边会自动收缩到画面主体，
  排除胶片黑/白边（逐帧独立处理，只向内收缩，不会切掉主体）。
  依赖打包内置的 Core ML 模型；如果 Mojave 无法加载模型，会自动退回
  纯启发式红框（保留黑边），不会崩溃。
- 新增命令行参数 --auto-import <路径> / --auto-identify / --auto-export，
  便于自动化冒烟测试。

说明：
- 界面与操作方式与 0.35.2-39 完全一致。
- 本包为 Intel(10.14)+Apple Silicon(11.0) 双架构。
TXT

cat > "$INSTALLER_PATH" <<'SCRIPT'
#!/bin/bash
set -e

APP_NAME="FionaSpotterTool.app"
OLD_APP_NAME="fiona spotter tool.app"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SOURCE_DIR/$APP_NAME"
TARGET_APP="/Applications/$APP_NAME"
OLD_TARGET_APP="/Applications/$OLD_APP_NAME"

if [ ! -d "$SOURCE_APP" ]; then
  echo "没有找到 $SOURCE_APP"
  read -n 1 -s -r -p "按任意键退出..."
  exit 1
fi

echo "正在安装 FionaSpotterTool 到 /Applications..."
if [ -e "$OLD_TARGET_APP" ]; then
  echo "正在删除旧版本 $OLD_TARGET_APP..."
  if ! rm -rf "$OLD_TARGET_APP" 2>/dev/null; then
    sudo rm -rf "$OLD_TARGET_APP"
  fi
fi
if [ -e "$TARGET_APP" ]; then
  echo "正在删除旧版本 $TARGET_APP..."
  if ! rm -rf "$TARGET_APP" 2>/dev/null; then
    sudo rm -rf "$TARGET_APP"
  fi
fi
if ! ditto "$SOURCE_APP" "$TARGET_APP" 2>/dev/null; then
  sudo ditto "$SOURCE_APP" "$TARGET_APP"
fi
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
xattr -cr "$TARGET_APP" 2>/dev/null || true
codesign --force --deep --sign - "$TARGET_APP" 2>/dev/null || true
echo "安装完成，正在打开..."
open "$TARGET_APP"
SCRIPT

chmod +x "$INSTALLER_PATH"

cat > "$DIAGNOSTIC_PATH" <<'SCRIPT'
#!/bin/bash
set -e

APP_NAME="FionaSpotterTool.app"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SOURCE_DIR/$APP_NAME"
TARGET_APP="/Applications/$APP_NAME"
LOG="$HOME/Desktop/fiona-spotter-tool-diagnostic.log"

echo "Diagnostic started: $(date)" > "$LOG"
echo "macOS: $(sw_vers -productVersion)" >> "$LOG"

if [ -d "$TARGET_APP" ]; then
  APP="$TARGET_APP"
else
  APP="$SOURCE_APP"
fi

echo "Using app: $APP" >> "$LOG"
xattr -dr com.apple.quarantine "$APP" 2>>"$LOG" || true
xattr -cr "$APP" 2>>"$LOG" || true
codesign --force --deep --sign - "$APP" >> "$LOG" 2>&1 || true

echo "Executable file:" >> "$LOG"
file "$APP/Contents/MacOS/fiona-spotter-tool-bin" >> "$LOG" 2>&1 || true
echo "Linked libraries:" >> "$LOG"
otool -L "$APP/Contents/MacOS/fiona-spotter-tool-bin" >> "$LOG" 2>&1 || true
echo "Launching via app launcher..." >> "$LOG"
"$APP/Contents/MacOS/fiona-spotter-tool" >> "$LOG" 2>&1 &

echo "诊断已启动，日志在桌面：fiona-spotter-tool-diagnostic.log"
echo "启动器日志在桌面：fiona-spotter-tool-mojave-launcher.log"
read -n 1 -s -r -p "按任意键关闭窗口..."
SCRIPT

chmod +x "$DIAGNOSTIC_PATH"

codesign --force --deep --sign - "$APP_DIR"
xattr -cr "$APP_DIR"
hdiutil create -volname "$RELEASE_NAME" -srcfolder "$RELEASE_DIR" -ov -format UDZO "$DMG_PATH"

echo "$APP_DIR"
echo "$DMG_PATH"
