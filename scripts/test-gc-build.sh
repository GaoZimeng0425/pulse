#!/bin/sh
# scripts/gc-build.sh 的行为测试(build-artifact-gc,2026-11-25)。
# 全部用临时目录里的合成夹具:不碰真实仓库、不碰真实 ~/Library,整轮 <1s。
# 守的是「删什么 / 绝不删什么」这两条线——这是个会 rm -rf 的脚本,规则一改必须有测试红。
#
# Usage: sh scripts/test-gc-build.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/gc-build.sh"
plistbuddy=/usr/libexec/PlistBuddy

tmp_parent="${TMPDIR:-/tmp}"
tmp=$(mktemp -d "${tmp_parent%/}/pulse-gc-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 1' HUP INT TERM

pass=0
fail=0

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "❌ $1: $2" >&2; }
assert_exists() { if [ -e "$2" ] || [ -L "$2" ]; then ok; else bad "$1" "应保留却被删了: $2"; fi; }
assert_missing() { if [ -e "$2" ] || [ -L "$2" ]; then bad "$1" "应删除却还在: $2"; else ok; fi; }
assert_status() { if [ "$gc_status" = "$2" ]; then ok; else bad "$1" "退出码应为 $2,实际 $gc_status"; fi; }

# ── 夹具 ──
old_file() { mkdir -p "${1%/*}"; : > "$1"; touch -t "$(date -v-40d +%Y%m%d%H%M)" "$1"; }
new_file() { mkdir -p "${1%/*}"; : > "$1"; }

# 像真的的 xcodebuild 产物目录:一个文件,旧或新
xcode_build() { mkdir -p "$1/Build/Products/Debug"; "$2" "$1/Build/Products/Debug/Pulse.debug.dylib"; }

# 像真的的 SwiftPM .build:下载副本(全旧)+ 编译结果 out(旧或新)+ 指向 out 的链接。
# 下载副本的名字取自本机实际布局(2026-11-25 实测);「它们被保留」正是要钉的行为。
spm_build() {  # $1 = .build 路径  $2 = old_file | new_file
  mkdir -p "$1/checkouts/GRDB" "$1/repositories/grdb.swift" "$1/artifacts" "$1/out/Products/Debug"
  old_file "$1/checkouts/GRDB/Row.swift"
  old_file "$1/repositories/grdb.swift/HEAD"
  old_file "$1/artifacts/binary.bin"
  old_file "$1/workspace-state.json"
  old_file "$1/manifest.pif"
  "$2" "$1/out/Products/Debug/Module.build/1.o"
  ln -s out/Products/Debug "$1/debug"
  ln -s out/Products/Release "$1/release"
}

# Xcode 系统目录里的一份产物:info.plist 记着它属于哪个工程
derived() {  # $1 = 目录  $2 = 记录的工程路径
  mkdir -p "$1"
  "$plistbuddy" -c "Add :WorkspacePath string $2" "$1/info.plist" >/dev/null
}

# 跑被测脚本:两个根都指到夹具;输出落 $log,退出码落 gc_status
run_gc() {  # $@ = 脚本参数
  log="$fx/out.log"
  PULSE_GC_MAIN_ROOT="$repo" PULSE_GC_DERIVED_DATA="$dd" sh "$script" "$@" > "$log" 2>&1
  gc_status=$?
}

# 标准场景:一个夹具摆齐全部「该删 / 不该删」的对象,跑一次后逐个断言。
mk_fixture() {
  fx="$tmp/$1"
  repo="$fx/repo"
  dd="$fx/dd"
  # 主目录:产物再旧也不动(合并后 build.sh 就在它上面施工)
  xcode_build "$repo/build" old_file
  spm_build "$repo/Packages/PulseCore/.build" old_file
  # idle-work:整个 worktree 连源码都旧 → 产物回收,目录与源码保留
  mkdir -p "$repo/.worktrees/idle-work/Pulse"
  xcode_build "$repo/.worktrees/idle-work/build" old_file
  spm_build "$repo/.worktrees/idle-work/Packages/PulseCore/.build" old_file
  old_file "$repo/.worktrees/idle-work/Pulse/View.swift"
  # half-idle:源码还在改、产物是旧的 → worktree 不算闲置,产物全留
  mkdir -p "$repo/.worktrees/half-idle/Pulse"
  xcode_build "$repo/.worktrees/half-idle/build" old_file
  spm_build "$repo/.worktrees/half-idle/Packages/PulseCore/.build" old_file
  new_file "$repo/.worktrees/half-idle/Pulse/View.swift"
  # busy-work:产物本身有新写入 → 全留
  mkdir -p "$repo/.worktrees/busy-work/Pulse.xcodeproj"
  xcode_build "$repo/.worktrees/busy-work/build" new_file
  spm_build "$repo/.worktrees/busy-work/Packages/PulseHelper/.build" new_file
  # Xcode 系统目录。Pulse-phys 记的是物理拼写(/private/var/…),脚本给的根是逻辑拼写
  repo_phys=$(cd "$repo" && pwd -P)
  derived "$dd/Pulse-gone" "$repo/.worktrees/gone/Pulse.xcodeproj"
  derived "$dd/Pulse-phys" "$repo_phys/.worktrees/gone/Pulse.xcodeproj"
  derived "$dd/Pulse-live" "$repo/.worktrees/busy-work/Pulse.xcodeproj"
  derived "$dd/Pulse-other" "/elsewhere/Other/Pulse.xcodeproj"
  derived "$dd/Other-project" "$repo/.worktrees/gone/Other.xcodeproj"
  mkdir -p "$dd/Pulse-noplist"
  mkdir -p "$fx/elsewhere/link-target"
  ln -s "$fx/elsewhere/link-target" "$dd/Pulse-link"
}

# ── 用例 1:默认运行——该删的删、不该删的一个不少 ──
mk_fixture default
run_gc
assert_status "默认运行" 0
assert_missing "Xcode 残留:工程已删" "$dd/Pulse-gone"
assert_missing "Xcode 残留:工程路径是解析后的拼写" "$dd/Pulse-phys"
assert_exists "Xcode:工程还在" "$dd/Pulse-live"
assert_exists "Xcode:不属于本仓" "$dd/Pulse-other"
assert_exists "Xcode:没有 info.plist" "$dd/Pulse-noplist"
assert_exists "Xcode:不是 Pulse- 前缀" "$dd/Other-project"
assert_exists "Xcode:目录是符号链接" "$dd/Pulse-link"
assert_exists "Xcode:符号链接的目标" "$fx/elsewhere/link-target"
assert_missing "闲置 worktree:xcodebuild 产物" "$repo/.worktrees/idle-work/build"
assert_missing "闲置 worktree:SwiftPM 编译结果 out" "$repo/.worktrees/idle-work/Packages/PulseCore/.build/out"
assert_missing "闲置 worktree:指向 out 的 debug 链接" "$repo/.worktrees/idle-work/Packages/PulseCore/.build/debug"
assert_missing "闲置 worktree:指向 out 的 release 链接" "$repo/.worktrees/idle-work/Packages/PulseCore/.build/release"
assert_exists "闲置 worktree:目录本身" "$repo/.worktrees/idle-work"
assert_exists "闲置 worktree:源码" "$repo/.worktrees/idle-work/Pulse/View.swift"
assert_exists "闲置 worktree:依赖源码下载副本" "$repo/.worktrees/idle-work/Packages/PulseCore/.build/checkouts/GRDB/Row.swift"
assert_exists "闲置 worktree:依赖仓库镜像" "$repo/.worktrees/idle-work/Packages/PulseCore/.build/repositories/grdb.swift/HEAD"
assert_exists "闲置 worktree:二进制产物下载" "$repo/.worktrees/idle-work/Packages/PulseCore/.build/artifacts/binary.bin"
assert_exists "闲置 worktree:workspace-state.json" "$repo/.worktrees/idle-work/Packages/PulseCore/.build/workspace-state.json"
assert_exists "闲置 worktree:manifest.pif" "$repo/.worktrees/idle-work/Packages/PulseCore/.build/manifest.pif"
assert_exists "半闲置 worktree(源码在改):xcodebuild 产物" "$repo/.worktrees/half-idle/build"
assert_exists "半闲置 worktree(源码在改):SwiftPM out" "$repo/.worktrees/half-idle/Packages/PulseCore/.build/out"
assert_exists "在用 worktree:xcodebuild 产物" "$repo/.worktrees/busy-work/build"
assert_exists "在用 worktree:SwiftPM out" "$repo/.worktrees/busy-work/Packages/PulseHelper/.build/out"
assert_exists "主目录:xcodebuild 产物" "$repo/build"
assert_exists "主目录:SwiftPM out" "$repo/Packages/PulseCore/.build/out"

# ── 用例 2:--dry-run 只列不删 ──
mk_fixture dry
run_gc --dry-run
assert_status "--dry-run" 0
assert_exists "预览:Xcode 残留未删" "$dd/Pulse-gone"
assert_exists "预览:闲置 worktree 产物未删" "$repo/.worktrees/idle-work/build"
assert_exists "预览:SwiftPM out 未删" "$repo/.worktrees/idle-work/Packages/PulseCore/.build/out"
if grep -q "Pulse-gone" "$log" && grep -q "idle-work/build" "$log"; then ok; else bad "预览" "输出里没列出将删项: $(cat "$log")"; fi

# ── 用例 3:闲置天数可调——调大后旧产物不算闲置,Xcode 残留不受天数影响 ──
mk_fixture days
PULSE_GC_IDLE_DAYS=400 PULSE_GC_MAIN_ROOT="$repo" PULSE_GC_DERIVED_DATA="$dd" sh "$script" > "$fx/out.log" 2>&1
gc_status=$?
assert_status "闲置天数调大" 0
assert_exists "天数调大:闲置 worktree 产物保留" "$repo/.worktrees/idle-work/build"
assert_missing "天数调大:Xcode 残留照删" "$dd/Pulse-gone"

# ── 用例 4:旧版 SwiftPM 布局(triple 目录)同样算编译结果 ──
mk_fixture legacy
legacy_dir="$repo/.worktrees/idle-work/Packages/PulseMCP/.build/arm64-apple-macosx/debug"
old_file "$legacy_dir/pulse-mcp"
old_file "$repo/.worktrees/idle-work/Packages/PulseMCP/.build/checkouts/swift-sdk/Package.swift"
run_gc
assert_status "旧布局" 0
assert_missing "旧布局:triple 目录回收" "$repo/.worktrees/idle-work/Packages/PulseMCP/.build/arm64-apple-macosx"
assert_exists "旧布局:下载副本保留" "$repo/.worktrees/idle-work/Packages/PulseMCP/.build/checkouts/swift-sdk/Package.swift"

# ── 用例 5:out 是指向别处的符号链接——只摘链接,不动目标 ──
mk_fixture outlink
pkg="$repo/.worktrees/idle-work/Packages/PulseCore/.build"
rm -rf "$pkg/out"
mkdir -p "$fx/elsewhere/shared-out"
old_file "$fx/elsewhere/shared-out/a.o"
ln -s "$fx/elsewhere/shared-out" "$pkg/out"
run_gc
assert_status "out 是符号链接" 0
assert_missing "符号链接 out:链接本身摘除" "$pkg/out"
assert_exists "符号链接 out:目标不动" "$fx/elsewhere/shared-out/a.o"

# ── 用例 6:坏参数拒绝执行,且什么都不删 ──
mk_fixture args
run_gc --bogus
assert_status "未知参数" 2
assert_exists "未知参数:什么都没删" "$dd/Pulse-gone"
PULSE_GC_IDLE_DAYS=abc PULSE_GC_MAIN_ROOT="$repo" PULSE_GC_DERIVED_DATA="$dd" sh "$script" > "$fx/out.log" 2>&1
gc_status=$?
assert_status "闲置天数不是数字" 2
PULSE_GC_IDLE_DAYS=0 PULSE_GC_MAIN_ROOT="$repo" PULSE_GC_DERIVED_DATA="$dd" sh "$script" > "$fx/out.log" 2>&1
gc_status=$?
assert_status "闲置天数为 0" 2
assert_exists "坏天数:什么都没删" "$dd/Pulse-gone"

# ── 用例 7:空仓库(没有 worktree、Xcode 目录是空的)→ 安静通过 ──
fx="$tmp/empty"
repo="$fx/repo"
dd="$fx/dd"
mkdir -p "$repo/.worktrees" "$dd"
run_gc
assert_status "空仓库" 0
if grep -q "无可回收" "$log"; then ok; else bad "空仓库" "输出没说明无可回收: $(cat "$log")"; fi

# ── 用例 8:Xcode 目录不存在也照样跑(只做 worktree 那一半)──
fx="$tmp/nodd"
repo="$fx/repo"
dd="$fx/no-such-dir"
xcode_build "$repo/.worktrees/idle-work/build" old_file
run_gc
assert_status "Xcode 目录不存在" 0
assert_missing "Xcode 目录不存在:worktree 产物照收" "$repo/.worktrees/idle-work/build"

# ── 用例 9:主目录路径不存在 → 报错退出,不碰任何东西 ──
fx="$tmp/noroot"
repo="$fx/nope"
dd="$fx/dd"
mkdir -p "$dd/Pulse-gone"
run_gc
assert_status "主目录不存在" 1
assert_exists "主目录不存在:什么都没删" "$dd/Pulse-gone"

if [ "$fail" = 0 ]; then
  echo "✅ gc-build 自测:通过 $pass · 失败 0"
  exit 0
fi
echo "❌ gc-build 自测:通过 $pass · 失败 $fail"
exit 1
