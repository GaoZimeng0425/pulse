#!/bin/sh
# 探针 09 — SMAppService daemon 注册路径实机验证(P3 探针①实机轮)
#
# 目的:验证「现有自签身份(无 OU/Team ID)+ SMAppService.daemon 注册」能否走通。
# 主路依据(文献轮,票 p3-root-mcp/01 Comments):Microsoft Procexp for Mac 实证
# 持久自签身份可行、ad-hoc 不可注册;唯一 gap = 我们的证书无 OU(Team ID 来源)。
# 本试验先用现有身份直接试——失败才升级为「重建带 OU 证书」拍板项。
#
# 用法(每步单独跑,别一口气全跑——register 需要用户在场点系统授权):
#   sh build-and-sign.sh        # 构建双可执行、组 bundle、双端签名、装 /Applications
#   open /Applications/PulseProbe.app   # 触发 register;结果落 /tmp/pulse-probe-register-result.txt
#   cat /tmp/pulse-probe-register-result.txt
#   cat /tmp/pulse-probe-root.marker   # 若 daemon 以 root 跑过则存在(uid=0 证明)
#
# 踩坑记档(随试验进展回填):
# - BundleProgram 用 bundle 相对路径(Procexp 先例),不是 Program/ProgramArguments。
# - 签名顺序:先 helper 二进制,再 app 可执行,最后整 bundle(codesign 外层封印)。
# - --options runtime --timestamp=none:hardened runtime 开着、自签无时间戳。
# - app 必须装在 /Applications(Procexp 用 ditto + rename 交换;试验直接 ditto)。
# - 复原:app 内 unregister();或系统设置 Login Items 里移除后删 app。
set -eu
cd "$(dirname "$0")"

IDENTITY="Pulse Local Code Signing"
APP="build/PulseProbe.app"
HELPER_NAME="com.pulse.probe.daemon"

rm -rf build && mkdir -p "build"
echo "==> 编译 helper 与宿主 app..."
swiftc -O Helper/main.swift -o "build/$HELPER_NAME"
swiftc -O HostApp/main.swift -o build/PulseProbeApp

echo "==> 组 bundle..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
cp build/PulseProbeApp "$APP/Contents/MacOS/PulseProbeApp"
cp "build/$HELPER_NAME" "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME"
chmod 755 "$APP/Contents/MacOS/PulseProbeApp" "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp "$HELPER_NAME.plist" "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME.plist"
plutil -lint "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME.plist"

echo "==> 双端签名(现有自签身份,hardened runtime,无时间戳)..."
codesign -f --options runtime --timestamp=none --sign "$IDENTITY" \
  --identifier "$HELPER_NAME" "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME"
codesign -f --options runtime --timestamp=none --sign "$IDENTITY" \
  --identifier com.pulse.probe "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -1

echo "==> 签名体检(Team ID 是否为空——文献轮 gap 的实锤点)..."
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier|Identifier|Authority" || true
codesign -dv "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME" 2>&1 | grep -E "TeamIdentifier|Identifier" || true

echo "==> 安装到 /Applications(独立名 PulseProbe.app,不碰真 Pulse)..."
rm -rf "/Applications/PulseProbe.app"
ditto "$APP" "/Applications/PulseProbe.app"

echo "✅ 就绪。下一步(须用户在场):open /Applications/PulseProbe.app"
echo "   register 结果: /tmp/pulse-probe-register-result.txt"
