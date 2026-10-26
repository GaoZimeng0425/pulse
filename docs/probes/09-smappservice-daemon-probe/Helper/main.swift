// 探针 09 helper —— 以 root 身份跑一次,写标记文件证明 uid=0,常驻 5 分钟供观察。
import Foundation

let uid = getuid()
let line = "pulse probe daemon ran at \(Date()) uid=\(uid) pid=\(getpid())\n"
try? line.write(toFile: "/tmp/pulse-probe-root.marker", atomically: true, encoding: .utf8)
Thread.sleep(forTimeInterval: 300)
