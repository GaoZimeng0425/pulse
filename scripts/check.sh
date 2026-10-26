#!/bin/sh
# Pulse 完整检查:lint + 构建 + 全量测试。合并进 main / 收口节点 / 大改动之后用;
# 提交级快速闸门见 .githooks/pre-commit(lint 只查 staged,构建不测试,增量)。
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

echo "🧹  1/3 lint(全仓,只读)"
sh scripts/lint.sh

echo "🛠  2/3 构建"
# 显式关签名与 build.sh 同款(本地部署签名归 build.sh 统一处理,构建门禁
# 只关心编译)。另:Xcode 27.1 偶发 "exit code 0 but produced no further
# output" 构建 flake(干净仓库也复现,重跑即绿,2026-10-26 观察记档)——
# check 全量跑挂先重跑一次再排查。
xcodebuild build \
  -project Pulse.xcodeproj \
  -scheme Pulse \
  -configuration Debug \
  -derivedDataPath build \
  -quiet \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
# MCP 可执行独立 SPM 包(p3-root-mcp/02),不进 app 构建图,单独构建把关。
swift build --package-path Packages/PulseMCP -q
# 特权助手独立 SPM 包(p3-root-mcp/03)同上。
swift build --package-path Packages/PulseHelper -q

echo "🧪  3/3 测试"
sh scripts/test.sh
