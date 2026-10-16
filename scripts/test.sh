#!/bin/sh
# Pulse 单元测试入口(骨架移植自 NemoNotch scripts/test.sh)。
# 完整输出落日志产物,结尾打印退出码 + 日志路径;报告测试结果时引用本
# 脚本的退出码与日志,不要转述。
#
# Usage:
#   sh scripts/test.sh                              # 全量单元测试
#   sh scripts/test.sh --only FooTests              # 只跑 FooTests
#   sh scripts/test.sh --only PulseTests/Foo/testBar  # 完整路径原样透传
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

only_flag=
if [ -n "$only" ]; then
  case "$only" in
    */*) only_flag="-only-testing:$only" ;;
    *)   only_flag="-only-testing:PulseTests/$only" ;;
  esac
fi

mkdir -p build
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
echo "   用例:通过 ${passed:-0} · 失败 ${failed:-0}"
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
