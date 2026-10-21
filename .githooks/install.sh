#!/bin/sh
# 一次性安装 Pulse git 闸门。仓库内任意位置执行:sh .githooks/install.sh
# 拷贝进共享 .git 目录而非设 core.hooksPath,主检出与未来 worktree 通吃;
# 改动 .githooks/ 下任何文件后重跑本脚本(pre-commit 的副本自检也会兜底)。
set -e

root=$(git rev-parse --show-toplevel)
common=$(git rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$root/$common" ;; esac

hooks="$common/hooks"
src="$root/.githooks"

mkdir -p "$hooks"
for h in pre-commit pre-merge-commit post-merge; do
  cp "$src/$h" "$hooks/$h"
  chmod +x "$hooks/$h"
done
# freshness.sh 刻意不复制:副本在启动时 source 主检出源目录里的它,检查器自身永不过期。

# 推进约定机械化:pull 只许快进;develop 的 pull 用 rebase 收敛;合并进 develop 保持 --no-ff
git config pull.ff only
git config branch.develop.rebase true
git config branch.develop.mergeoptions "--no-ff"

echo "✅ Pulse git 闸门已安装: $hooks/{pre-commit,pre-merge-commit,post-merge}"
echo "   pre-commit:副本自检 → Swift lint(SwiftFormat 自动修 + SwiftLint error 拦截)→ 构建 + 核心测试编译门禁;绕过:PULSE_SKIP_BUILD=1 / --no-verify"
echo "   pre-merge-commit:main/master 与 p1-implementation 禁止 merge 提交;绕过:--no-verify"
echo "   post-merge:merge 落在 develop → sh scripts/build.sh Release 安装;跳过:PULSE_SKIP_BUILD=1;干跑:PULSE_HOOK_DEBUG=1"
echo "   config:pull.ff=only · branch.develop.rebase=true · branch.develop.mergeoptions=--no-ff"

# lint 门禁依赖 swiftlint + swiftformat;缺工具时 pre-commit 会拦截提交(防假绿)。
missing=""
for tool in swiftlint swiftformat; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  echo "⚠️  未安装:$missing — pre-commit lint 会拦截提交。安装:brew install$missing"
fi
