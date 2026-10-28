#!/bin/bash
# 14-worktree-list.sh — p4-cleaner/01 探针④:git worktree list 输出形状 + 真孤儿样本
# 问:worktree list --porcelain 的字段形状;"仓库外并排目录是否孤儿"用真样本验证(pulse 的 .worktrees vs SwarmAgents-wt-*)。
set -u

echo "== ① pulse 仓(有活跃 worktree:.worktrees/p4-probes) =="
cd /Users/aa00930/Documents/Learn/macos/pulse
git worktree list --porcelain
echo "-- 普通格式:"
git worktree list

echo
echo "== ② SwarmAgents 仓(目录列表里有两个 -wt- 并排目录,疑似孤儿) =="
cd /Users/aa00930/Documents/Learn/macos/SwarmAgents 2>/dev/null || { echo "仓不存在"; exit 0; }
git worktree list --porcelain
echo "-- 登记里的 worktree 路径 vs 磁盘上的并排目录:"
ls -d /Users/aa00930/Documents/Learn/macos/SwarmAgents* 2>/dev/null

echo
echo "== ③ 判定验证 =="
for d in /Users/aa00930/Documents/Learn/macos/SwarmAgents-wt-*; do
  name=$(basename "$d")
  if git worktree list --porcelain | grep -q "worktree $d"; then
    echo "  $name: git 登记中(不是孤儿)"
  else
    echo "  $name: git 不登记 → 孤儿候选(还需查进程活动)"
    # 是不是 git 仓本身(独立 clone 会带 .git 目录,不是 worktree 残留)
    if [ -d "$d/.git" ]; then echo "    但它有 .git 目录 → 独立 clone,不是 worktree 残留(规则表要区分)"; fi
  fi
done
echo
echo "== ④ worktree 残留的真实形状(prunable/detached 样本) =="
git worktree list --porcelain | grep -B1 -A2 "detached\|prunable" | head -10
echo "(空 = 当前无 detached/prunable 样本,输出形状仍以 ①② 为准)"
