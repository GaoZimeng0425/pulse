#!/bin/bash
# 12-trash-structure.sh — p4-cleaner/01 探针②:废纸篓多卷结构 + NSWorkspace.recycle 行为
# 问:~/.Trash 与各卷 .Trashes 的真实形状/权限模型;recycle 对文件与目录的行为与去向;无权限项长什么样。
set -u
UID_N=$(id -u)

echo "== ① ~/.Trash 结构 =="
ls -la ~/.Trash 2>&1 | head -8
echo "条目数: $(ls -A ~/.Trash 2>/dev/null | wc -l | tr -d ' ')"
du -sh ~/.Trash 2>/dev/null

echo
echo "== ② 各卷 .Trashes 结构 =="
echo "-- /.Trashes(启动卷真身,经 / 直达)"
ls -la /.Trashes 2>&1 | head -8
echo "   本用户($UID_N)条目数: $(ls -A /.Trashes/$UID_N 2>/dev/null | wc -l | tr -d ' ')"
for v in /Volumes/*; do
  echo "-- $v"
  if [ -d "$v/.Trashes" ]; then
    ls -la "$v/.Trashes" 2>&1 | head -8
    echo "   本用户($UID_N)目录内容(前3):"
    ls -A "$v/.Trashes/$UID_N" 2>/dev/null | head -3
    echo "   本用户目录条目数: $(ls -A "$v/.Trashes/$UID_N" 2>/dev/null | wc -l | tr -d ' ')"
  else
    echo "   (无 .Trashes 或不可读)"
  fi
done

echo
echo "== ③ 权限模型 =="
echo "在 /.Trashes 下建本 UID 目录(预期允许或已存在):"
mkdir -p /.Trashes/$UID_N 2>&1 && echo OK || true
echo "建别人的 UID 目录(预期 EPERM——sticky bit 只许动自己的):"
mkdir /.Trashes/999999 2>&1 | head -1
echo "动启动卷 /.Trashes 权限位: $(stat -f '%Sp %Su:%Sg' /.Trashes 2>&1)"
echo "本机可写外置卷(有才有跨卷场景): $(ls /Volumes/ | grep -v '^Macintosh HD$\|^Recovery$' | tr '\n' ' ')"
echo "(无外置卷 → 跨卷 .Trashes 行为留待外置卷在场时补测,如实记档)"

echo
echo "== ④ NSWorkspace.recycle:文件与目录 =="
TMPD=$(mktemp -d)
echo "probe-file-content" > "$TMPD/p4probe-file.txt"
mkdir -p "$TMPD/p4probe-dir/inner" && echo x > "$TMPD/p4probe-dir/inner/a.txt"
cat > "$TMPD/recycle.swift" <<'SWIFT'
import AppKit
let args = Array(CommandLine.arguments.dropFirst())
var out: [String] = []
for path in args {
    let before = Date()
    NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { newURLs, error in
        let dest = newURLs.values.first?.path ?? "?"
        out.append("\(path) -> \(error == nil ? "OK 去向=\(dest)" : "ERR \(error?.localizedDescription ?? "?")") \(Int(Date().timeIntervalSince(before) * 1000))ms")
    }
    // recycle 的完成 handler 是异步的;等一拍
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
}
out.forEach { print($0) }
SWIFT
swift "$TMPD/recycle.swift" "$TMPD/p4probe-file.txt" "$TMPD/p4probe-dir"
sleep 1
echo "回收后 ~/.Trash 新增(找 p4probe):"
ls -A ~/.Trash | grep -i p4probe || echo "(没找到——注意 macOS 会去重改名)"
echo "源目录残留: $(ls -A "$TMPD" | grep -v recycle.swift | wc -l | tr -d ' ') 项"
echo " Finder 恢复验证(把文件捞回来):"
osascript -e 'tell application "Finder" to get name of every item of trash' 2>/dev/null | tr ',' '\n' | grep -i p4probe | head -3
rm -rf "$TMPD"
echo "(废纸篓里的 p4probe 项请随手清掉,或留着 08 票手工观察)"

echo
echo "== ⑤ 跨卷废纸篓(有外置卷才有效) =="
echo "可写外置卷: $(ls /Volumes/ | grep -v '^Macintosh HD$' | tr '\n' ' ')"
