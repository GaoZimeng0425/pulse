#!/bin/sh
# 分层门禁(arch-clean/01):功能层 / 视图层不得构造 Live 层类型。
#
# 规则:`Pulse/Live/` 里声明的任何类型(按声明收集,不靠 Live 前缀——不少适配器名字不带
# 前缀),不许在 `Pulse/Features/`、`Pulse/Views/` 里以 `类型名(` 构造。组装只在 `Pulse/App/`。
# 静态调用(`类型.方法(`)不在本条规则内(纯规则 / 纯数据挪出 Live 由 arch-clean/02 负责)。
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
  '^\s*(?:(?:public|internal|private|fileprivate|final|nonisolated|@\w+)\s+)*(class|struct|enum|actor)\s+([A-Z]\w*)' \
  Pulse/Live --type swift | sort -u | paste -sd'|' -)
if [ -z "$types" ]; then
  echo "❌ 分层门禁:没在 Pulse/Live 收集到类型声明,脚本口径失效" >&2
  exit 1
fi

# 每处越界记成「文件 类型」;同文件同类型多处只记一条(清单按文件 × 类型记账)。
# 去掉整行注释与行尾注释后再匹配,注释里提到类型名不算。
current=$(rg -n --no-heading "\\b($types)\\(" Pulse/Features Pulse/Views --type swift \
  | sed -E 's#^([^:]+):[0-9]+:(.*)$#\1\t\2#' \
  | awk -F'\t' -v types="$types" '
      {
        code = $2
        sub(/\/\/.*/, "", code)
        if (match(code, "(^|[^A-Za-z0-9_.])(" types ")\\(")) {
          name = substr(code, RSTART, RLENGTH - 1)
          sub(/^[^A-Za-z0-9_]/, "", name)
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
  echo "❌ 分层门禁:功能层 / 视图层构造了 Live 层类型(组装只许在 Pulse/App/):" >&2
  printf '   %s\n' "$new" >&2
  echo "   改法:由组装点(MonitorAssembly / CleanAssembly / InertSources)构造后注入。" >&2
fi
if [ -n "$stale" ]; then
  status=1
  echo "" >&2
  echo "❌ 分层门禁:以下豁免已不再出现,请从 $baseline 删掉对应行(清单只许变短):" >&2
  printf '   %s\n' "$stale" >&2
fi
[ "$status" = 0 ] && echo "✅ 分层门禁通过(存量豁免 $(printf '%s\n' "$expected" | grep -c .) 条)"
exit $status
