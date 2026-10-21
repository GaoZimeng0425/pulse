#!/bin/sh
# Pulse 完整检查:lint + 构建 + 全量测试。合并进 main / 收口节点 / 大改动之后用;
# 提交级快速闸门见 .githooks/pre-commit(lint 只查 staged,构建不测试,增量)。
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

echo "🧹  1/3 lint(全仓,只读)"
sh scripts/lint.sh

echo "🛠  2/3 构建"
xcodebuild build \
  -project Pulse.xcodeproj \
  -scheme Pulse \
  -configuration Debug \
  -derivedDataPath build \
  -quiet

echo "🧪  3/3 测试"
sh scripts/test.sh
