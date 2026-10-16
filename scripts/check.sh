#!/bin/sh
# Pulse 完整检查:构建 + 全量测试。合并进 main / 收口节点 / 大改动之后用;
# 提交级快速闸门见 .githooks/pre-commit(只构建不测试,增量)。
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

echo "🛠  1/2 构建"
xcodebuild build \
  -project Pulse.xcodeproj \
  -scheme Pulse \
  -configuration Debug \
  -derivedDataPath build \
  -quiet

echo "🧪  2/2 测试"
sh scripts/test.sh
