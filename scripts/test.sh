#!/bin/sh
# Pulse 单元测试入口(骨架移植自 NemoNotch scripts/test.sh)。
# 完整输出落日志产物,结尾打印退出码 + 日志路径;报告测试结果时引用本
# 脚本的退出码与日志,不要转述。
#
# 两套测试(arch-review-2026-10-18/05):核心包 PulseCore 的测试用 `swift test` 跑,不起
# app 宿主;app 侧(Live 冒烟 / SwiftUI / 功能模块薄壳)用 xcodebuild 宿主测试。
#
# Usage:
#   sh scripts/test.sh                              # 全量:核心包 + app 两套
#   sh scripts/test.sh --only FooTests              # 只跑 FooTests(在核心包就走 swift test)
#   sh scripts/test.sh --only PulseTests/Foo/testBar  # 完整路径原样透传(app 侧)
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      [ $# -ge 2 ] || { echo "usage: sh scripts/test.sh [--only <TestClass>]" >&2; exit 2; }
      only="$2"; shift 2 ;;
    *)
      echo "usage: sh scripts/test.sh [--only <TestClass|full/testing/path>]" >&2
      exit 2 ;;
  esac
done

core_dir="$root/Packages/PulseCore"
mkdir -p build
core_log="$root/build/test-core.log"
core_passed=0

# 核心包测试:全量时必跑;--only 指向核心包里的套件时只跑它,并且不再跑 app 侧。
run_core() {
  filter_flag=""
  [ -n "${1:-}" ] && filter_flag="--filter $1"
  echo "🧪 swift test(PulseCore)${1:+ --filter $1} — 完整日志: $core_log"
  # shellcheck disable=SC2086
  (cd "$core_dir" && swift test $filter_flag) > "$core_log" 2>&1
  core_status=$?
  core_passed=$(grep -c "' passed" "$core_log" || true)
  core_failed=$(grep -c "' failed" "$core_log" || true)
  echo "   核心包:通过 ${core_passed:-0} · 失败 ${core_failed:-0}"
  if [ "$core_status" != 0 ]; then
    echo "❌ 核心包测试失败(退出码 $core_status)— 失败用例:"
    grep -E "' failed|error:" "$core_log" | head -20
    echo "   完整日志: $core_log"
    exit "$core_status"
  fi
}

if [ -n "$only" ] && [ "${only#*/}" = "$only" ] && [ -f "$core_dir/Tests/PulseCoreTests/$only.swift" ]; then
  run_core "$only"
  if [ "${core_passed:-0}" -eq 0 ]; then
    echo "❌ 退出码 0 但没有任何用例被执行 — --only 过滤器无匹配" >&2
    exit 1
  fi
  echo "✅ 测试通过(退出码 0)"
  exit 0
fi
[ -z "$only" ] && run_core ""

only_flag=
if [ -n "$only" ]; then
  case "$only" in
    */*) only_flag="-only-testing:$only" ;;
    *)   only_flag="-only-testing:PulseTests/$only" ;;
  esac
fi

log="$root/build/test.log"

echo "🧪 xcodebuild test ${only_flag:-(全部)} — 完整日志: $log"

# 输出整体重定向到日志而不是 tee:POSIX sh 拿不到管道里 xcodebuild 的退出码,
# 而退出码正是要交付的证据。摘要与失败详情在结尾从日志中提取。
xcodebuild test \
  -project Pulse.xcodeproj \
  -scheme Pulse \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  $only_flag \
  > "$log" 2>&1
status=$?

echo "── 摘要 ──────────────────────────────"
# Swift Testing 输出 "Test 'x()' passed on ...",XCTest 输出
# "Test Case '-[...]' passed (...)"——"' passed" 锚点两者通吃。
passed=$(grep -c "' passed" "$log" || true)
failed=$(grep -c "' failed" "$log" || true)
echo "   app 侧:通过 ${passed:-0} · 失败 ${failed:-0}"
[ -z "$only" ] && echo "   用例:通过 $(( ${passed:-0} + ${core_passed:-0} )) · 失败 ${failed:-0}(核心包 + app)"
if [ "$status" != 0 ]; then
  echo ""
  echo "❌ 测试失败(退出码 $status)— 失败用例:"
  grep -E "' failed" "$log" | head -20
  echo ""
  echo "   日志尾 40 行:"
  tail -40 "$log"
  echo ""
  echo "   完整日志: $log"
  echo "   重跑单个: sh scripts/test.sh --only <TestClass>"
  exit $status
fi
# 零用例守卫:xcodebuild 对无匹配的 -only-testing 静默跑 0 个测试且返回 0
# —— 套件名拼错/已改名时这就是假绿;测试 target 接线断裂的全量跑同样落
# 在这里。宁可误杀,不可静默放行。
if [ "${passed:-0}" -eq 0 ] && [ "${failed:-0}" -eq 0 ]; then
  echo "❌ 退出码 0 但没有任何用例被执行 — --only 过滤器无匹配或测试 target 接线断裂" >&2
  echo "   完整日志: $log" >&2
  exit 1
fi
echo "✅ 测试通过(退出码 0)"
echo "   完整日志: $log"
exit 0
