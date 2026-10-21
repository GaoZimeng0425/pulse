#!/bin/sh
# 已安装副本 vs 源文件一致性自检 — 被 pre-commit 的**已安装副本** source。本文件
# 自身不被 install.sh 复制,始终从主检出的源目录读取,所以检查逻辑永远是
# 最新的(不会出现「检查器自己过期」的递归问题)。(基线取自 NemoNotch 同款。)
#
# 背景:install.sh 把 .githooks/ 下的 hooks cp 进共享 .git 目录,提交/合并跑的
# 是那份副本。源改了不重装 = 静默跑旧代码,排障时会盯着一份根本没在执行的源
# 文件。「改了要重跑 install.sh」原本只是注释里的一句提醒 — 这里把它变成机制。
#
# 行为:发现任一副本与源不一致 → 自动重装(sh .githooks/install.sh)→ 返回 1,
# 调用方中止当前命令并提示重跑(本次已在跑旧副本,不能让它继续)。
#
# 用法(调用方):
#   . "$primary/.githooks/freshness.sh"
#   pulse_check_fresh "$primary" || exit 1
pulse_check_fresh() {
  # 显式逃生口:在 worktree 里开发 hooks 自身时,主检出的源还是旧的,自检会把
  # 副本"修正"回旧版 — 这时按需跳过(用完即撤)。
  if [ "${PULSE_SKIP_FRESHNESS:-0}" = "1" ]; then
    echo "⏭  PULSE_SKIP_FRESHNESS=1 — 跳过已安装副本自检" >&2
    return 0
  fi
  pf_root="$1"
  pf_src="$pf_root/.githooks"
  pf_common=$(git -C "$pf_root" rev-parse --git-common-dir)
  case "$pf_common" in /*) ;; *) pf_common="$pf_root/$pf_common" ;; esac

  pf_stale=""
  for pf_pair in \
      "pre-commit:hooks/pre-commit" \
      "pre-merge-commit:hooks/pre-merge-commit" \
      "post-merge:hooks/post-merge"; do
    pf_s="$pf_src/${pf_pair%%:*}"
    pf_d="$pf_common/${pf_pair#*:}"
    [ -f "$pf_s" ] || continue   # 源里没有的(基于旧 develop)不算过期
    if [ ! -f "$pf_d" ] || ! cmp -s "$pf_s" "$pf_d"; then
      pf_stale="$pf_stale ${pf_pair%%:*}"
    fi
  done
  [ -z "$pf_stale" ] && return 0

  echo "" >&2
  echo "✋ .githooks 源与已安装副本不一致:$pf_stale" >&2
  echo "   正在重新安装(sh .githooks/install.sh)…" >&2
  if sh "$pf_src/install.sh" >/dev/null 2>&1; then
    echo "   ✅ 已重装。本次命令用的是旧副本,已中止 — 请重新执行刚才的命令。" >&2
  else
    echo "   ❌ 自动重装失败 — 手动执行: sh \"$pf_src/install.sh\"" >&2
  fi
  echo "" >&2
  return 1
}
