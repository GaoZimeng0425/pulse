#!/bin/bash
# Pulse Release 安装链(骨架参考 NemoNotch build.sh;裁剪:无 DMG / 无
# exportArchive —— 那两样是分发给别人用的,本项目 ad-hoc 签名、自用,
# Release 产物直接可装。要分发再补 --dmg)。
# 一条命令:Release 构建 → 优雅退出正在运行的实例(留退出日志)→
# 换 /Applications 副本 → 拉起。日常换新版就跑它。
# 用法: sh scripts/build.sh
set -euo pipefail

PROJECT="Pulse.xcodeproj"
SCHEME="Pulse"
APP_NAME="Pulse"
BUILD_DIR="build"
INSTALL_PATH="/Applications/$APP_NAME.app"

cd "$(dirname "$0")/.."

echo "==> Release 构建..."
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -quiet

APP_BUNDLE="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_BUNDLE" ] || { echo "❌ 未找到产物 $APP_BUNDLE" >&2; exit 1; }

echo "==> 优雅退出正在运行的 $APP_NAME..."
# LSUIElement 应用按 bundle id 寻址更稳;quit 走 NSApp.terminate,
# 会触发 LogService 的退出留痕。
osascript -e 'tell application id "com.gaozimeng.pulse" to quit' 2>/dev/null || true
sleep 1
pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> 安装到 $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$APP_BUNDLE" "$INSTALL_PATH"

echo "==> 拉起 $APP_NAME..."
open "$INSTALL_PATH"
echo "==> 完成,$APP_NAME 已从 /Applications 运行。"
