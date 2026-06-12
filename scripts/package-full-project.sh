#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ImgSlicer"
APP_VERSION="0.35.2"
APP_BUILD="37"
DIST_DIR="$ROOT_DIR/dist"
APP_RELEASE_NAME="$APP_NAME-$APP_VERSION-$APP_BUILD"
FULL_NAME="$APP_NAME-FullProject-$APP_VERSION-$APP_BUILD"
FULL_DIR="$DIST_DIR/$FULL_NAME"
ZIP_PATH="$DIST_DIR/$FULL_NAME.zip"

cd "$ROOT_DIR"

bash "$ROOT_DIR/scripts/package-mac.sh"

rm -rf "$FULL_DIR" "$ZIP_PATH"
mkdir -p "$FULL_DIR/可运行安装包" "$FULL_DIR/项目源码"

ditto "$DIST_DIR/$APP_RELEASE_NAME" "$FULL_DIR/可运行安装包/$APP_RELEASE_NAME"

cp "$ROOT_DIR/Package.swift" "$FULL_DIR/项目源码/Package.swift"
cp "$ROOT_DIR/icon-human-scissor-dark-v2.svg" "$FULL_DIR/项目源码/icon-human-scissor-dark-v2.svg"
cp "$ROOT_DIR/imgslicer-v33-requirements.md" "$FULL_DIR/项目源码/imgslicer-v33-requirements.md"
cp "$ROOT_DIR/mockup-v33.html" "$FULL_DIR/项目源码/mockup-v33.html"
cp "$ROOT_DIR/algorithm-comparison.md" "$FULL_DIR/项目源码/algorithm-comparison.md"
cp "$ROOT_DIR/requirements.txt" "$FULL_DIR/项目源码/requirements.txt"
cp "$ROOT_DIR/app.py" "$FULL_DIR/项目源码/app.py"
ditto "$ROOT_DIR/Sources" "$FULL_DIR/项目源码/Sources"
ditto "$ROOT_DIR/scripts" "$FULL_DIR/项目源码/scripts"
ditto "$ROOT_DIR/imgs" "$FULL_DIR/项目源码/imgs-测试图片"

cat > "$FULL_DIR/README-先看.txt" <<TXT
ImgSlicer 完整交付包

目录说明：

1. 可运行安装包/${APP_RELEASE_NAME}
   给其他 Mac 直接运行使用。进入这个目录后双击“安装.command”。

2. 项目源码
   当前项目源码、需求/设计文件、图标、测试图片和打包脚本。没有包含 .build、.venv、输出图片等本机缓存。

其他 Mac 打开方式：

1. 解压本 zip。
2. 打开“可运行安装包/${APP_RELEASE_NAME}”。
3. 双击“安装.command”。
4. 如果系统提示无法打开脚本，请右键“安装.command”选择“打开”。

如果仍提示“应用已损坏”，原因通常是 macOS Gatekeeper 对微信/浏览器传来的未公证应用加了隔离标记。
安装脚本已经会自动执行清除隔离和本机 ad-hoc 签名。

正式无提示分发说明：

当前包是本地测试签名。若要让任何 Mac 都像普通软件一样双击打开，需要使用 Apple Developer ID 证书签名并提交 Apple notarization 公证。

源码编译：

需要 macOS 14 或更高版本，以及 Xcode/Swift 工具链。
在项目源码目录执行：

swift build

重新打包：

bash scripts/package-mac.sh
TXT

ditto -c -k --sequesterRsrc --keepParent "$FULL_DIR" "$ZIP_PATH"

echo "$ZIP_PATH"
