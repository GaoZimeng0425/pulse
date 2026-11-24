#!/bin/sh
# 分层门禁(arch-clean/01 起,06 收紧):功能层 / 视图层不得引用 Live 层类型。
#
# 规则:`Pulse/Live/` 里声明的任何类型 / 协议 / 类型别名(按声明收集,不靠 Live 前缀——不少
# 适配器名字不带前缀),不许在 `Pulse/Features/`、`Pulse/Views/` 里以任何形式出现:构造、
# 属性 / 参数类型、静态调用、协议一致性都算。纯值与端口放 PulseCore(或功能层),组装只在
# `Pulse/App/`。
#
# 存量用豁免清单 scripts/layer-baseline.txt 记账,只许变短:
#   - 新出现的越界 → 失败;
#   - 清单里的某条已经修掉、却没从清单删 → 也失败(提示删行),清单不会悄悄变成摆设。
#
# Usage: sh scripts/check-layers.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
baseline=scripts/layer-baseline.txt

types=$(rg --no-filename -o -r '$2' \
  '^\s*(?:(?:public|internal|private|fileprivate|final|nonisolated|@\w+)\s+)*(class|struct|enum|actor|protocol|typealias)\s+([A-Z]\w*)' \
  Pulse/Live --type swift | sort -u | paste -sd'|' -)
if [ -z "$types" ]; then
  echo "❌ 分层门禁:没在 Pulse/Live 收集到类型声明,脚本口径失效" >&2
  exit 1
fi

# 每处越界记成「文件 类型」;同文件同类型多处只记一条(清单按文件 × 类型记账)。
# 去掉整行注释与行尾注释后再匹配,注释里提到类型名不算。
current=$(rg -n --no-heading -w "($types)" Pulse/Features Pulse/Views --type swift \
  | sed -E 's#^([^:]+):[0-9]+:(.*)$#\1\t\2#' \
  | awk -F'\t' -v types="$types" '
      {
        code = $2
        sub(/\/\/.*/, "", code)
        while (match(code, "(^|[^A-Za-z0-9_])(" types ")([^A-Za-z0-9_]|$)")) {
          name = substr(code, RSTART, RLENGTH)
          code = substr(code, RSTART + RLENGTH - 1)
          sub(/^[^A-Za-z0-9_]/, "", name)
          sub(/[^A-Za-z0-9_]$/, "", name)
          print $1 " " name
        }
      }' \
  | sort -u)

expected=$(grep -v '^\s*#' "$baseline" | grep -v '^\s*$' | sort -u)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$current" | grep -v '^$' > "$tmp/current"
printf '%s\n' "$expected" | grep -v '^$' > "$tmp/expected"
new=$(comm -23 "$tmp/current" "$tmp/expected")
stale=$(comm -13 "$tmp/current" "$tmp/expected")

status=0
if [ -n "$new" ]; then
  status=1
  echo "" >&2
  echo "❌ 分层门禁:功能层 / 视图层引用了 Live 层类型(组装只许在 Pulse/App/):" >&2
  printf '%s\n' "$new" | sed 's/^/   /' >&2
  echo "   改法:纯值 / 端口挪 PulseCore,Live 实现由组装点(MonitorAssembly / CleanAssembly / InertSources)构造后注入。" >&2
fi
if [ -n "$stale" ]; then
  status=1
  echo "" >&2
  echo "❌ 分层门禁:以下豁免已不再出现,请从 $baseline 删掉对应行(清单只许变短):" >&2
  printf '%s\n' "$stale" | sed 's/^/   /' >&2
fi
[ "$status" = 0 ] && echo "✅ 分层门禁通过(存量豁免 $(printf '%s\n' "$expected" | grep -c .) 条)"
exit $status
