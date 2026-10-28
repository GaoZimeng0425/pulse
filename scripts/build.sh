#!/bin/bash
# Pulse Release 安装链(骨架参考 NemoNotch build.sh;裁剪:无 DMG / 无
# exportArchive —— 那两样是分发给别人用的,本项目本地自签、自用,
# Release 产物直接可装。要分发再补 --dmg)。
# 一条命令:Release 构建 → 稳定身份重签 → 优雅退出正在运行的实例(留退出
# 日志)→ 换 /Applications 副本 → 拉起。日常换新版就跑它。
# 用法: sh scripts/build.sh
set -euo pipefail

PROJECT="Pulse.xcodeproj"
SCHEME="Pulse"
APP_NAME="Pulse"
BUILD_DIR="build"
INSTALL_PATH="/Applications/$APP_NAME.app"

# ── 本地部署自签(2026-10-24,照搬 NemoNotch 2026-10-20 方案)──────────────
# ad-hoc 每次重建换 cdhash,TCC/Keychain 授权全丢 = 每次重装都被当陌生 app
# 重新弹权限框(蓝牙票 p2-sensors/06 补记的"一直提示"根因之二)。改用登录钥匙串里的
# 稳定自签身份:授权锚定在证书上,重装不丢。
# 判据用 codesign 实签探针(find-identity -p codesigning 对无信任设置的自签
# 证书不显示,不能当存在性检查,NemoNotch 实测)。
# 生成/重建证书:sh scripts/make-signing-cert.sh
# 显式逃生口(临时 ad-hoc):PULSE_SIGNING_IDENTITY=-
SIGNING_IDENTITY="${PULSE_SIGNING_IDENTITY:-Pulse Local Code Signing}"
if [ "$SIGNING_IDENTITY" != "-" ]; then
  probe=$(mktemp) && printf 'probe' > "$probe"
  if ! codesign -f -s "$SIGNING_IDENTITY" "$probe" >/dev/null 2>&1; then
    echo "✋ 签名身份 '$SIGNING_IDENTITY' 解析不到 — 拒绝静默回退 ad-hoc。"
    echo "   重建: sh scripts/make-signing-cert.sh"
    echo "   临时显式回退: PULSE_SIGNING_IDENTITY=- sh scripts/build.sh"
    rm -f "$probe"
    exit 1
  fi
  rm -f "$probe"
fi
echo "==> 签名身份: $SIGNING_IDENTITY"

cd "$(dirname "$0")/.."

echo "==> Release 构建..."
# xcodebuild 侧关掉签名(它只会 ad-hoc),产物由下方统一重签;Debug / 测试
# 构建不走本链路,保持 ad-hoc(NemoNotch 同款分工:本地部署签名,CI/测试 ad-hoc)。
# SPM 包克隆共享缓存:worktree 的 xcodebuild 是全新克隆,pinned revision 在代理网络下
# 拉不动(2026-10-28 两个 worktree 连续复现,主仓 build/SourcePackages 已暖从不失败);
# 全部 xcodebuild 指向同一缓存后,worktree 零网络解析。PULSE_SPM_CACHE 可覆盖。
pkg_cache="${PULSE_SPM_CACHE:-$HOME/Library/Caches/pulse-swiftpm}"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
 \
  -clonedSourcePackagesDirPath "$pkg_cache"  -quiet \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

APP_BUNDLE="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_BUNDLE" ] || { echo "❌ 未找到产物 $APP_BUNDLE" >&2; exit 1; }

# MCP stdio server(p3-root-mcp/02):全静态单一可执行,嵌 bundle 随 app 分发;
# 必须在重签前进 bundle(--deep 签名覆盖它)。
echo "==> 构建 pulse-mcp(MCP stdio server)..."
swift build -c release --package-path Packages/PulseMCP -q
cp "Packages/PulseMCP/.build/release/pulse-mcp" "$APP_BUNDLE/Contents/MacOS/pulse-mcp"

# 特权助手 daemon(p3-root-mcp/03,探针 09 安装组合):可执行 + plist 嵌
# Contents/Library/LaunchDaemons/(SMAppService.daemon 的既定位置);同样在
# 重签前进 bundle。
echo "==> 构建 pulse-helper(特权助手 daemon)..."
swift build -c release --package-path Packages/PulseHelper -q
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchDaemons"
cp "Packages/PulseHelper/.build/release/pulse-helper" "$APP_BUNDLE/Contents/Library/LaunchDaemons/pulse-helper"
cp "Packages/PulseHelper/com.gaozimeng.pulse.helper2.plist" "$APP_BUNDLE/Contents/Library/LaunchDaemons/"
chmod 755 "$APP_BUNDLE/Contents/Library/LaunchDaemons/pulse-helper"

if [ "$SIGNING_IDENTITY" != "-" ]; then
  echo "==> 重签($SIGNING_IDENTITY)..."
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
fi

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
