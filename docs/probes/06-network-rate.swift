// p1-history/06 真机探针:用 app 自己的网络代码路径(核心层 NetworkInterfaceSelector
// + NetworkRateDiffer,app 侧 NetworkCountersReader)采样,观察速率是否 sane。
// 用法:sh docs/probes/06-network-rate.sh <轮数> [下载URL](源码跨两层,编译步骤在脚本里)
// 输出逐轮:选定接口 / 累计计数 / 差分速率;下载 URL 非空时第 1 轮后启动 curl 造流量。

import Foundation

let rounds = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 4 : 4
let url = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

let primarySource = SCDynamicStorePrimaryInterfaceSource()
let listSource = GetifaddrsInterfaceListSource()
let source = LiveNetworkCountersSource()

print("主接口(SCDynamicStore): \(primarySource.primaryInterfaceName() ?? "nil")")
print("utun/虚拟口在册: \(listSource.interfaces().map(\.name).filter { NetworkInterfaceSelector.isVirtual($0) }.joined(separator: ","))")
print("---")

var previous: NetworkCounters?
var trafficTask: Process?
for round in 1...max(1, rounds) {
    if round == 2, let url, let out = URL(string: url) {
        // 造流量:curl 拉一段公开文件到 /dev/null。
        trafficTask = Process()
        trafficTask?.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        trafficTask?.arguments = ["-sS", "-o", "/dev/null", "--max-time", "12", out.absoluteString]
        try? trafficTask?.run()
        print(">> curl 已启动(造流量)")
    }
    // 走 app 同一条路:LiveNetworkCountersSource(含入向死表回退)。
    guard let counters = source.sample() else {
        print("轮 \(round): 读不到(无可用接口)")
        previous = nil
        sleep(5)
        continue
    }
    let result = NetworkRateDiffer.result(previous: previous, current: counters)
    previous = counters
    let rates = result.rates
    print(String(
        format: "轮 %d: 接口=%@ 上=%.1f KB/s 下=%.1f KB/s (增量 上%llu B 下%llu B, 线速 %@)",
        round, counters.interface,
        rates.upBytesPerSecond / 1_000,
        rates.downBytesPerSecond / 1_000,
        result.upBytesDelta, result.downBytesDelta,
        counters.linkBaudrateBitsPerSecond.map { "\($0 / 1_000_000) Mbps" } ?? "未知"
    ))
    sleep(5)
}
trafficTask?.waitUntilExit()
print("done")
