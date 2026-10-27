// pulse-helper —— Pulse 特权助手 daemon(p3-root-mcp/03;探针 09 亲儿子形状)。
// root 运行:60s 循环 powermetrics 单发采 per-process Energy Impact,聚合结果
// 写 /var/run/com.gaozimeng.pulse.helper.json(root 域文件,用户态不可伪造);
// app 侧轮询读该文件。**不走 XPC/launchd mach bootstrap**——2026-10-27 全天
// 实证:带 MachServices 的自签 helper 在本机被 xpcproxy 以 EX_CONFIG/Launch
// Constraint 拒(exit 78,0 秒退出);无 MachServices + BundleProgram 相对路径
// + 批准链 = 探针 09 唯一从头到尾跑通的组合(root marker 实证),本形状
// 与它完全一致。安全性:文件在 /var/run 只有 root 可写;app 侧做形状校验,
// 伪造面 = root = 已出信任边界(与 XPC 时代 client 侧不校验的收窄同口径)。
import Foundation
import PulseHelperCore

let outputPath = "/var/run/com.gaozimeng.pulse.helper.json"

func writeSnapshot(_ collector: EnergyCollector) {
    var lines: [String] = []
    for sample in collector.samples {
        let name = sample.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        lines.append("{\"pid\":\(sample.pid),\"name\":\"\(name)\",\"impact\":\(sample.impact)}")
    }
    let epochMs = Int(collector.collectedAt.timeIntervalSince1970 * 1000)
    let json = "{\"epochMs\":\(epochMs),\"rows\":[\(lines.joined(separator: ","))]}"
    try? Data(json.utf8).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
}

PowermetricsParser.debugLog("启动(文件通信版)")
let collector = EnergyCollector()
collector.collect()
writeSnapshot(collector)
PowermetricsParser.debugLog("首轮写入完成,\(collector.samples.count) 行 → \(outputPath)")

while true {
    Thread.sleep(forTimeInterval: 60)
    collector.collect()
    writeSnapshot(collector)
}
