#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ImgSlicer-Mojave"
VERSION="0.35.12-mojave"
BUILD="48"
BUILD_DIR="$ROOT_DIR/.build/mojave"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/$APP_NAME-$VERSION-$BUILD"
APP_DIR="$RELEASE_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-$BUILD.zip"

rm -rf "$RELEASE_DIR" "$ZIP_PATH"
mkdir -p "$BUILD_DIR" "$MACOS" "$RESOURCES" "$FRAMEWORKS"

SOURCES=(
  "$ROOT_DIR/Sources/ImgSlicerMojave/MojaveMain.swift"
  "$ROOT_DIR/Sources/ImgSlicer/Models.swift"
  "$ROOT_DIR/Sources/ImgSlicer/FolderScanner.swift"
  "$ROOT_DIR/Sources/ImgSlicer/ExternalDetector.swift"
  "$ROOT_DIR/Sources/ImgSlicer/ImageProcessor.swift"
  "$ROOT_DIR/Sources/ImgSlicer/Processing/CropDetectionPipeline.swift"
  "$ROOT_DIR/Sources/ImgSlicer/Processing/CropEditStore.swift"
  "$ROOT_DIR/Sources/ImgSlicer/Processing/SampleLibrary.swift"
)

CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" swiftc \
  -swift-version 5 \
  -parse-as-library \
  -D IMGSLICER_MOJAVE \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -target x86_64-apple-macosx10.14 \
  -O \
  -framework AppKit \
  -framework Vision \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${SOURCES[@]}" \
  -o "$MACOS/$APP_NAME"

cp "$ROOT_DIR/Sources/ImgSlicer/Resources/icon.svg" "$RESOURCES/icon.svg"
# The host SDK's iconutil currently rejects its own generated iconset. Keep the
# SVG in Resources and let Mojave use the generic app icon until a prebuilt,
# verified .icns is added to the repository.

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>local.imgslicer.mojave</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>ImgSlicer Mojave</string>
<key>CFBundlePackageType</key><string>APPL</string>
$(if [ -f "$RESOURCES/AppIcon.icns" ]; then echo '<key>CFBundleIconFile</key><string>AppIcon</string>'; fi)
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>10.14.6</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

SWIFT_STDLIB_TOOL="$(xcrun --find swift-stdlib-tool 2>/dev/null || true)"
if [ -n "$SWIFT_STDLIB_TOOL" ]; then
  "$SWIFT_STDLIB_TOOL" --copy --scan-executable "$MACOS/$APP_NAME" --destination "$FRAMEWORKS" --platform macosx
fi

cat > "$RELEASE_DIR/安装.command" <<'INSTALL'
#!/bin/bash
set -e
SOURCE="$(cd "$(dirname "$0")" && pwd)/ImgSlicer-Mojave.app"
TARGET="/Applications/ImgSlicer-Mojave.app"
rm -rf "$TARGET" 2>/dev/null || sudo rm -rf "$TARGET"
ditto "$SOURCE" "$TARGET" 2>/dev/null || sudo ditto "$SOURCE" "$TARGET"
xattr -cr "$TARGET" 2>/dev/null || true
codesign --force --deep --sign - "$TARGET"
open "$TARGET"
INSTALL
chmod +x "$RELEASE_DIR/安装.command"

codesign --force --deep --sign - "$APP_DIR"
xattr -cr "$APP_DIR"
ditto -c -k --keepParent "$RELEASE_DIR" "$ZIP_PATH"
echo "$APP_DIR"
echo "$ZIP_PATH"
