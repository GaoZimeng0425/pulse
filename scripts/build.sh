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

# ── 发布签名:Apple Development 证书(release-dev-signing,2026-11-22)──────
# 历史两层,别混:
# ① TCC/授权稳定:锚定证书,重装不丢——Apple Development 同样满足(固定身份,
#    非临时签名);换证书那次会重弹授权(一次性,已记档)。
# ② 守护进程 Launch Constraint(11-22 定谳):macOS 26 对系统级后台程序校验
#    签名里的**开发者团队身份**——自签证书没有,ad-hoc 更没有,launchd 每次
#    15ms 拒 spawn(OS_REASON_CODESIGNING)。唯一活路 = 有 Team 身份的证书,
#    即 Apple Development(Xcode 已登录的 Apple ID 免费签发,一年有效期)。
# 注意:换签名身份 = 系统视 Pulse 为陌生 app,**一次性**重弹 TCC 授权框
# (蓝牙/通知/音频捕获逐个允许),助手也要重新批准一次——记档的一次性成本。
# 证书过期预警:探针顺带检查剩余有效期(<30 天响亮警告)。
# 显式逃生口(临时 ad-hoc,助手将无法运行):PULSE_SIGNING_IDENTITY=-
SIGNING_IDENTITY="${PULSE_SIGNING_IDENTITY:-Apple Development}"
if [ "$SIGNING_IDENTITY" != "-" ]; then
  probe=$(mktemp) && printf 'probe' > "$probe"
  if ! codesign -f -s "$SIGNING_IDENTITY" "$probe" >/dev/null 2>&1; then
    echo "✋ 签名身份 '$SIGNING_IDENTITY' 解析不到 — 拒绝静默回退 ad-hoc。"
    echo "   铸造/刷新: xcodebuild -allowProvisioningUpdates 走 Xcode 已登录 Apple ID"
    echo "   (AGENTS.md 构建节有完整口径;证书一年有效,过期即重铸)"
    echo "   临时显式回退: PULSE_SIGNING_IDENTITY=- sh scripts/build.sh"
    rm -f "$probe"
    exit 1
  fi
  rm -f "$probe"
  # 过期预警:证书链里找 Apple Development 的剩余天数(<30 天警告)。
  expiry=$(security find-certificate -a -c "Apple Development" -p login.keychain-db 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  # openssl 的到期日是英文月份(「Nov 19 06:02:40 2027 GMT」):解析必须钉 C locale——
  # 中文系统下 %b 只认「11月」,解析失败曾被当成 0(1970 年)算出「剩 -20783 天」。
  # 读不出就如实说,不拿假数字报警。
  if [ -n "$expiry" ]; then
    end_epoch=$(LC_ALL=C date -j -u -f "%b %d %H:%M:%S %Y GMT" "$expiry" "+%s" 2>/dev/null || true)
    if [ -n "$end_epoch" ]; then
      days=$(( (end_epoch - $(date +%s)) / 86400 ))
      if [ "$days" -lt 30 ]; then
        echo "⚠️  Apple Development 证书仅剩 ${days} 天有效——过期后签名失效,需重铸(release-dev-signing 记档)"
      fi
    else
      echo "⚠️  读不出 Apple Development 证书到期日(「${expiry}」),跳过有效期检查"
    fi
  fi
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
# 指纹稳定策略(energy-gate-fix;battery-energy/02 守卫修正):SMAppService 按
# 内容指纹批准守护进程——覆盖 helper = 已批准条目立即作废,用户被迫重批。
# 探针 2026-11-23 定谳:同一身份重复签名,文件字节随 signingTime 变(跨秒必变,
# sha 守卫在签名时代必误报),但 cdhash 恒稳——改为**先签新产物再比 cdhash**
# (BTM/Launch Constraint 认的代码身份),源码没动的常规发版零误报,真变了
# 才换并响亮提醒。注意 codesign -d 的诊断输出走 stderr,提取必须 2>&1(评审
# P1 实证:2>/dev/null 下 stdout 恒空,守卫恒判「变了」)。
echo "==> 构建 pulse-helper(特权助手 daemon)..."
swift build -c release --package-path Packages/PulseHelper -q
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchDaemons"
NEW_HELPER="Packages/PulseHelper/.build/release/pulse-helper"
INSTALLED_HELPER="$APP_BUNDLE/Contents/Library/LaunchDaemons/pulse-helper"
if [ "$SIGNING_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGNING_IDENTITY" "$NEW_HELPER"
fi
cdhash() { codesign -dvvv "$1" 2>&1 | grep '^CDHash=' | awk -F= '/^CDHash=/{print $2}'; }
if [ -f "$INSTALLED_HELPER" ] \
  && [ -n "$(cdhash "$NEW_HELPER")" ] \
  && [ "$(cdhash "$NEW_HELPER")" = "$(cdhash "$INSTALLED_HELPER")" ]; then
  echo "==> 特权助手代码指纹(cdhash)未变,保留已装机版本(系统批准继续有效)"
else
  if [ -f "$INSTALLED_HELPER" ]; then
    echo "⚠️  特权助手已更新:装机后需到 设置 → 通用 关开一次「特权助手」开关,"
    echo "⚠️  并在 系统设置 → 通用 → 登录项与扩展 重新允许一次(macOS 按内容指纹批准守护进程)"
  fi
  cp "$NEW_HELPER" "$INSTALLED_HELPER"
fi
cp "Packages/PulseHelper/com.gaozimeng.pulse.helper2.plist" "$APP_BUNDLE/Contents/Library/LaunchDaemons/"
cp "Packages/PulseHelper/com.gaozimeng.pulse.helper3.plist" "$APP_BUNDLE/Contents/Library/LaunchDaemons/"
chmod 755 "$APP_BUNDLE/Contents/Library/LaunchDaemons/pulse-helper"

if [ "$SIGNING_IDENTITY" != "-" ]; then
  echo "==> 重签($SIGNING_IDENTITY)..."
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  # 守护进程必须显式单独签:--deep(deprecated)不保证覆盖 LaunchDaemons 里的
  # 独立可执行文件,swift build 产物的 ad-hoc 签名残留 → 与宿主身份不符 →
  # macOS 26 Launch Constraint 直接拒 spawn(OS_REASON_CODESIGNING,
  # 2026-11-22 定谳:BTM 批准一直为真,助手自发布脚本接管装机起从未跑起)。
  codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE/Contents/Library/LaunchDaemons/pulse-helper"
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
