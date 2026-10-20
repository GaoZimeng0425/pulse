#!/bin/sh
# p1-history/06 真机探针的编译运行入口。探针走 app 的网络代码路径,源码分在两层:
# Live 适配器(Pulse/Live/NetworkSensor.swift)与核心层纯逻辑(PulseCore 的 NetworkModel.swift)。
# 这里把两份源去掉 `import PulseCore` 后与探针(改名 main.swift,允许顶层代码)同模块编译。
#
# Usage: sh docs/probes/06-network-rate.sh [轮数] [下载URL]
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for src in "$root/Pulse/Live/NetworkSensor.swift" "$root/Packages/PulseCore/Sources/PulseCore/NetworkModel.swift"; do
  sed '/^import PulseCore$/d' "$src" > "$work/$(basename "$src")"
done
cp "$root/docs/probes/06-network-rate.swift" "$work/main.swift"

swiftc "$work"/*.swift -o "$work/probe06"
"$work/probe06" "$@"
