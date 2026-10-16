#!/bin/sh
# 一次性安装 Pulse git 闸门。仓库内任意位置执行:sh .githooks/install.sh
# 拷贝进共享 .git 目录而非设 core.hooksPath,主检出与未来 worktree 通吃;
# 改动 .githooks/ 下任何文件后重跑本脚本。
set -e

root=$(git rev-parse --show-toplevel)
common=$(git rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$root/$common" ;; esac

hooks="$common/hooks"
mkdir -p "$hooks"
cp "$root/.githooks/pre-commit" "$hooks/pre-commit"
chmod +x "$hooks/pre-commit"

echo "✅ Pulse git 闸门已安装: $hooks/pre-commit"
echo "   规则:staged 含 .swift → 增量构建,失败拦截;绕过:--no-verify"
