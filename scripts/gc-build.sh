#!/bin/sh
# Pulse 构建产物回收(build-artifact-gc,2026-11-25 用户拍板)。
# 由 .githooks/post-merge 在 build.sh 之前调用;手动:sh scripts/gc-build.sh [--dry-run]
#
# 为什么要有它:构建产物只增不减,没有任何东西会删——
#   - Xcode 按「工程路径」在系统目录存产物:哪个 worktree 在 Xcode 里打开过,就留下
#     约 760M;worktree 删了它也不删(2026-11-25 实测:arch-clean-01/03/05 三份 2.3G)。
#   - 每个 worktree 的编译产物用满约 3G(xcodebuild build/ + 各包 .build),worktree
#     合并完忘删就一直占着。Xcode 自己没有自动清理的设置(27 才加了手动命令)。
#
# 规则只有两条:
#   ① Xcode 残留:~/Library/Developer/Xcode/DerivedData/Pulse-* 里,info.plist 记的工程
#      路径属于本仓、且该路径已经不存在 → 整份删。
#   ② 闲置 worktree 的编译结果:.worktrees/* 整个 worktree 连续 N 天(默认 14)没有任何
#      文件被写过 → 删它的 build/,以及各包 .build 里的编译结果(out 及指向它的链接)。
#      闲置按「整个 worktree」判,不是只看产物:源码还在改的 worktree,产物再旧也不动,
#      省得它下次构建全量重编。
#
# 绝不碰:主目录(合并后 build.sh 就在它上面施工)、源码、分支、worktree 目录本身、
#   .build 里的依赖下载副本(checkouts / repositories / artifacts / workspace-state.json)、
#   ~/Library/Caches 下的共享缓存、别的项目(Xcode 目录里非 Pulse- 前缀,或工程路径不在本仓)。
# 凭什么:
#   - 下载副本要留:2026-11-24 缓存目录被清坏后构建退出码 74,靠留存的副本回填才恢复;
#     代理网络下重新拉 pinned revision 拉不动(2026-10-28 两个 worktree 连续复现)。
#   - worktree 目录不自动删:会话的当前目录可能还在里面,删了 = 之后每条命令都起不来
#     (spawn ENOENT,2026-11-13 / 11-22 四犯)。
#   - 删的只是能重新编译出来的东西:判错(把在用的判成闲置)的代价是一次全量重编。
#
# 行为由 scripts/test-gc-build.sh 钉住(合成夹具,不碰真实仓库)。
set -u

root=$(cd "$(dirname "$0")/.." && pwd)

dry=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    *) echo "usage: sh scripts/gc-build.sh [--dry-run]" >&2; exit 2 ;;
  esac
done

gc_days="${PULSE_GC_IDLE_DAYS:-14}"
case "$gc_days" in
  ''|*[!0-9]*) echo "✋ PULSE_GC_IDLE_DAYS 必须是正整数,收到:'$gc_days'" >&2; exit 2 ;;
esac
[ "$gc_days" -ge 1 ] || { echo "✋ PULSE_GC_IDLE_DAYS 必须是正整数,收到:'$gc_days'" >&2; exit 2; }

# 主检出 = git 登记的第一个 worktree,所有 .worktrees/* 都挂在它下面。
# PULSE_GC_MAIN_ROOT / PULSE_GC_DERIVED_DATA 是给 test-gc-build.sh 用的接缝(指到夹具)。
if [ -n "${PULSE_GC_MAIN_ROOT:-}" ]; then
  main="$PULSE_GC_MAIN_ROOT"
else
  main=$(git -C "$root" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
fi
if [ -z "${main:-}" ] || [ ! -d "$main" ]; then
  echo "✋ 找不到主检出目录(git worktree list 的第一项)— 不做任何回收。" >&2
  exit 1
fi
# Xcode 记下的工程路径可能是符号链接解析后的拼写(/var → /private/var),两种都认。
main_phys=$(cd "$main" && pwd -P)
wt_root="$main/.worktrees"
gc_dd="${PULSE_GC_DERIVED_DATA:-${HOME:-}/Library/Developer/Xcode/DerivedData}"

# 先全查完落进计划文件,再统一删:扫描阶段出任何错都不会已经删了一半。
tmp_parent="${TMPDIR:-/tmp}"
plan="${tmp_parent%/}/pulse-gc-plan.$$"
: > "$plan"
trap 'rm -f "$plan"' EXIT
trap 'rm -f "$plan"; exit 1' HUP INT TERM
tab=$(printf '\t')

# 目录里只要有一个普通文件在 N 天内被写过,就不算闲置(不跟符号链接)。
gc_is_idle() {
  [ -z "$(find "$1" -type f -mtime -"$gc_days" -print -quit 2>/dev/null)" ]
}

# .build 里算「编译结果」的条目:只有这些名字会被删,其余一律不动。
# 名字取自本机 SwiftBuild 版 SwiftPM 的实际布局(2026-11-25 实测:out,外加指向它的
# debug / release 链接);旧版布局的 <triple> 目录(*-apple-*)一并覆盖。
spm_compiled_parts() {  # $1 = .build 路径
  b=$1
  for name in out debug release; do
    [ -e "$b/$name" ] || [ -L "$b/$name" ] || continue
    printf '%s\n' "$b/$name"
  done
  for e in "$b"/*-apple-*/; do
    [ -d "$e" ] && [ ! -L "$e" ] || continue
    printf '%s\n' "${e%/}"
  done
}

plan_add() {  # $1 = 类别  $2 = 路径  $3 = 说明
  kb=$(du -sk "$2" 2>/dev/null | cut -f1)
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${kb:-0}" "$3" >> "$plan"
}

# ── ① Xcode 残留 ──
if [ -d "$gc_dd" ]; then
  for d in "$gc_dd"/Pulse-*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue   # 符号链接不跟:目标可能在别处
    [ -f "$d/info.plist" ] || continue          # 认不出归属的,宁可留着
    ws=$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null) || continue
    [ -n "$ws" ] || continue
    rel=""
    case "$ws" in
      "$main_phys"/*) rel=".${ws#"$main_phys"}" ;;
      "$main"/*) rel=".${ws#"$main"}" ;;
      *) continue ;;                            # 不是本仓的工程
    esac
    [ -e "$ws" ] && continue                    # 工程还在 = 还会用到
    plan_add xcode "$d" "工程 $rel 已不存在"
  done
fi

# ── ② 闲置 worktree 的编译结果 ──
if [ -d "$wt_root" ] && [ ! -L "$wt_root" ]; then
  for wt_dir in "$wt_root"/*/; do
    wt="${wt_dir%/}"
    [ -d "$wt" ] && [ ! -L "$wt" ] || continue
    gc_is_idle "$wt" || continue
    if [ -d "$wt/build" ] && [ ! -L "$wt/build" ]; then
      plan_add xcbuild "$wt/build" "worktree ${wt##*/} ${gc_days} 天无写入"
    fi
    for bb in "$wt"/Packages/*/.build; do
      [ -d "$bb" ] && [ ! -L "$bb" ] || continue
      # 管道里的循环跑在子 shell:计划落在文件上,所以这里不受影响。
      spm_compiled_parts "$bb" | while IFS= read -r part; do
        [ -n "$part" ] && plan_add spm "$part" "worktree ${wt##*/} ${gc_days} 天无写入,只收编译结果"
      done
    done
  done
fi

if [ ! -s "$plan" ]; then
  echo "🧹 构建产物回收:无可回收(Xcode 残留 0 · 闲置 worktree 产物 0)"
  exit 0
fi

# 最后一道闸:只认这几种形状的路径,越界一律拒绝——防上面的扫描逻辑日后被改坏后误删。
gc_remove() {  # $1 = 类别  $2 = 路径
  case "$2" in */../*|*/..|../*)
    echo "   ✋ 拒绝删除(路径含 ..): $2" >&2; return 1 ;;
  esac
  case "$1:$2" in
    xcode:"$gc_dd"/Pulse-*) ;;
    xcbuild:"$wt_root"/*/build) ;;
    spm:"$wt_root"/*/Packages/*/.build/out | spm:"$wt_root"/*/Packages/*/.build/debug | \
    spm:"$wt_root"/*/Packages/*/.build/release | spm:"$wt_root"/*/Packages/*/.build/*-apple-*) ;;
    *)
      echo "   ✋ 拒绝删除(路径不在允许范围内): $2" >&2; return 1 ;;
  esac
  if [ -L "$2" ] || [ -f "$2" ]; then rm -f "$2"; else rm -rf "$2"; fi
}

human_kb() {  # $1 = KB
  awk -v kb="$1" 'BEGIN {
    if (kb >= 1048576) printf "%.1fG", kb / 1048576
    else if (kb >= 1024) printf "%.0fM", kb / 1024
    else printf "%dK", kb
  }'
}

kind_label() {
  case "$1" in
    xcode) printf 'Xcode 残留' ;;
    xcbuild) printf 'xcodebuild 产物' ;;
    spm) printf 'SwiftPM 编译结果' ;;
  esac
}

if [ "$dry" = 1 ]; then
  echo "==> 构建产物回收(预览,未删)"
else
  echo "==> 构建产物回收"
fi
total_kb=0
count=0
failed=0
while IFS="$tab" read -r kind path kb note; do
  [ -n "$kind" ] || continue
  total_kb=$((total_kb + kb))
  count=$((count + 1))
  if [ "$dry" = 1 ]; then
    printf '   [预览] %s  %s  (%s,%s)\n' "$(kind_label "$kind")" "$path" "$(human_kb "$kb")" "$note"
  elif gc_remove "$kind" "$path"; then
    printf '   回收 %s  %s  (%s,%s)\n' "$(kind_label "$kind")" "$path" "$(human_kb "$kb")" "$note"
  else
    failed=$((failed + 1))
  fi
done < "$plan"

if [ "$dry" = 1 ]; then
  echo "🧹 构建产物回收(预览):$count 项,共 $(human_kb "$total_kb");去掉 --dry-run 才真删"
  exit 0
fi
echo "🧹 构建产物回收:已回收 $count 项,共 $(human_kb "$total_kb")"
[ "$failed" = 0 ]
