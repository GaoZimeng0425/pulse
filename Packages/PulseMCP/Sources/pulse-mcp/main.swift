// pulse-mcp —— Pulse 的 MCP stdio server(p3-root-mcp/02)。
// 读 Pulse 历史库(WAL 只读)回答:谁在吃 CPU / 当前读数 / 历史趋势;
// app 不在跑也能答(分钟级落库数据,年龄如实标注)。
// 分发:嵌 Pulse.app/Contents/MacOS/,AI 客户端以 stdio 方式拉起本可执行。
import Foundation
import MCP
import PulseCore

let server = Server(
    name: "pulse",
    version: "0.1.0",
    instructions: """
    Pulse 菜单栏系统监视器的数据查询。数据为分钟级采样落库(非实时流),\
    每个答案都会标注数据年龄;Pulse app 未运行时仍可回答(回退最近落库)。
    """,
    capabilities: .init(tools: .init())
)

// MARK: - 取数与格式化

private func ageText(atSeconds: Int, now: Date) -> String {
    let age = max(0, HistoryWindows.epochSeconds(of: now) - atSeconds)
    if age < 90 {
        return "\(age) 秒前"
    }
    if age < 90 * 60 {
        return "\(age / 60) 分钟前"
    }
    return "\(age / 3600) 小时前"
}

/// 打开只读库;打不开时返回给客户端的诚实文案。
private func withDatabase(_ body: (PulseDatabase, Date) throws -> String) -> String {
    do {
        guard let queue = try HistoryDatabase.openReader() else {
            return "Pulse 历史库不存在——本机还没跑过 Pulse(首次运行后即建库)。"
        }
        let now = Date()
        return try queue.read { db in try body(db, now) }
    } catch {
        return "查询失败:\(error)"
    }
}

private func whyCpuHighText(topN: Int, lookbackMinutes: Int) -> String {
    withDatabase { db, now in
        let top = try InsightQuery.topCpuGroups(
            limit: topN, lookbackMinutes: lookbackMinutes, now: now, in: db
        )
        if top.isEmpty {
            return "历史库最近 \(lookbackMinutes) 分钟没有进程样本(Pulse 未运行,或刚启动还没落库)。"
        }
        var lines = ["最近 \(lookbackMinutes) 分钟 CPU 占用最高的 \(top.count) 个组(进程口径,不含内核):"]
        for (index, group) in top.enumerated() {
            var line = "\(index + 1). \(group.name) — 平均 \(PulseFormat.cpuPercent(group.cpuAverage)),峰值 \(PulseFormat.cpuPercent(group.cpuPeak)),内存峰值 \(PulseFormat.memory(UInt64(max(0, group.memoryMaxBytes))))(\(group.processCount) 进程)"
            if let project = group.projectRoot {
                line += ",项目:\(project)"
            }
            lines.append(line)
        }
        let snapshot = try InsightQuery.latestSnapshot(now: now, in: db)
        if let load = snapshot.systemLoad {
            lines
                .append(
                    "系统负载(全部核含内核):\(PulseFormat.cpuPercent(load.value))(\(ageText(atSeconds: load.atSeconds, now: now)))"
                )
        }
        if let newest = snapshot.newestSampleSeconds {
            lines.append("数据新鲜度:最近落库 \(ageText(atSeconds: newest, now: now))")
        }
        return lines.joined(separator: "\n")
    }
}

private func currentMetricsText() -> String {
    withDatabase { db, now in
        let snapshot = try InsightQuery.latestSnapshot(now: now, in: db)
        if snapshot.newestSampleSeconds == nil, snapshot.newestSystemSeconds == nil {
            return "历史库为空——Pulse 尚未落库(首次运行数分钟后再试)。"
        }
        var lines: [String] = []
        if let cpu = snapshot.cpuSumPercent {
            lines
                .append(
                    "CPU(全组合计,进程口径):\(PulseFormat.cpuPercent(cpu.value))(\(ageText(atSeconds: cpu.atSeconds, now: now)))"
                )
        }
        if let load = snapshot.systemLoad {
            lines
                .append(
                    "系统负载(全部核,含内核):\(PulseFormat.cpuPercent(load.value))(\(ageText(atSeconds: load.atSeconds, now: now)))"
                )
        }
        if let memory = snapshot.memoryBytes {
            lines
                .append(
                    "内存(全组峰值合计):\(PulseFormat.memory(UInt64(max(0, memory.value))))(\(ageText(atSeconds: memory.atSeconds, now: now)))"
                )
        }
        if let network = snapshot.networkBytesPerSec {
            lines
                .append(
                    "网络(收发合计):\(PulseFormat.diskRate(network.value))(\(ageText(atSeconds: network.atSeconds, now: now)))"
                )
        }
        if let disk = snapshot.diskBytesPerSec {
            lines
                .append("磁盘(读写合计):\(PulseFormat.diskRate(disk.value))(\(ageText(atSeconds: disk.atSeconds, now: now)))")
        }
        if let temp = snapshot.gauges[GaugeKey.tempAverage.rawValue] {
            lines
                .append(
                    "温度(CPU 均值):\(String(format: "%.1f°C", temp.value))(\(ageText(atSeconds: temp.atSeconds, now: now)))"
                )
        }
        if let gpu = snapshot.gauges[GaugeKey.gpuUtilization.rawValue] {
            lines.append("GPU 利用率:\(PulseFormat.cpuPercent(gpu.value))(\(ageText(atSeconds: gpu.atSeconds, now: now)))")
        }
        let powerKeys = GaugeKey.powerKeys.map(\.rawValue)
        let powerSum = powerKeys.compactMap { snapshot.gauges[$0]?.value }.reduce(0, +)
        if powerKeys.contains(where: { snapshot.gauges[$0] != nil }) {
            lines
                .append(
                    "功率(五路合计):\(PulseFormat.watts(powerSum))(\(ageText(atSeconds: snapshot.gauges[powerKeys[0]]?.atSeconds ?? 0, now: now)))"
                )
        }
        if lines.isEmpty {
            return "历史库没有可用的最新读数。"
        }
        return lines.joined(separator: "\n")
    }
}

private func historyQueryText(metricRaw: String, rangeRaw: String, breakdownID: String?) -> String {
    guard let metric = HistoryMetricKey(rawValue: metricRaw) else {
        return "未知 metric「\(metricRaw)」。可用:\(HistoryMetricKey.allCases.map(\.rawValue).joined(separator: ", "))"
    }
    guard let range = HistoryRange(rawValue: rangeRaw) else {
        return "未知 range「\(rangeRaw)」。可用:\(HistoryRange.allCases.map(\.rawValue).joined(separator: ", "))"
    }
    let breakdown = breakdownID.flatMap { id in metric.breakdowns.first { $0.id == id } }
    return withDatabase { db, now in
        let series = try HistoryQuery.series(
            metric: metric, breakdown: breakdown, range: range, now: now, in: db
        )
        if series.isEmpty {
            return "\(metric.title)/\(range.title) 窗口内没有落库数据(Pulse 未运行或该指标未记录)。"
        }
        guard let statistics = series.statistics() else {
            return "\(metric.title)/\(range.title) 窗口内没有落库数据。"
        }
        var lines = [
            "\(metric.title)\(breakdown.map { "·\($0.title)" } ?? "")(\(range.title)):"
                + "均值 \(metric.statisticText(statistics.average)),峰值 \(metric.statisticText(statistics.peak))"
                + ";数据覆盖 \(series.filledCount)/\(series.values.count) 桶(桶宽 \(series.bucketSeconds)s,缺桶 = app 未运行)",
        ]
        let tail = series.values.suffix(12).enumerated()
            .compactMap { offset, value -> String? in
                guard let value else { return nil }
                let bucketIndex = series.values.count - 12 + offset
                let at = series.startSeconds + bucketIndex * series.bucketSeconds
                return "\(ageText(atSeconds: at, now: now)) \(metric.statisticText(value))"
            }
        if !tail.isEmpty {
            lines.append("最近各桶:" + tail.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 工具注册

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [
        Tool(
            name: "why_cpu_high",
            description: "回答\"为什么 CPU 高\":最近时间窗内 CPU 占用最高的进程组排行(名称/项目/均值/峰值/内存),附系统负载与数据年龄。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "top_n": .object([
                        "type": .string("integer"),
                        "description": .string("返回组数,默认 5"),
                    ]),
                    "lookback_minutes": .object([
                        "type": .string("integer"),
                        "description": .string("回看窗口(分钟),默认 10"),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "current_metrics",
            description: "Pulse 最近一档读数:CPU/系统负载/内存/网络/磁盘/温度/GPU/功率,每项标注数据年龄(分钟级采样,非实时)。",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        Tool(
            name: "history_query",
            description: "查历史趋势曲线的窗口统计与最近各桶值(30 天内)。metric: systemLoad/cpu/memory/network/disk/temperature/gpu/power;range: hour1/day1/days7/days30。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "metric": .object([
                        "type": .string("string"),
                        "description": .string("指标名,见工具描述"),
                    ]),
                    "range": .object([
                        "type": .string("string"),
                        "description": .string("时间窗,见工具描述"),
                    ]),
                    "breakdown": .object([
                        "type": .string("string"),
                        "description": .string("可选分项:temperatureAverage/temperatureHottest/powerTotal/power.<domain>"),
                    ]),
                ]),
                "required": .array([.string("metric"), .string("range")]),
            ])
        ),
    ])
}

await server.withMethodHandler(CallTool.self) { params in
    let arguments = params.arguments ?? [:]
    let text: String
    switch params.name {
    case "why_cpu_high":
        let topN = arguments["top_n"]?.intValue ?? 5
        let lookback = arguments["lookback_minutes"]?.intValue ?? 10
        text = whyCpuHighText(
            topN: max(1, min(20, topN)), lookbackMinutes: max(1, min(1440, lookback))
        )
    case "current_metrics":
        text = currentMetricsText()
    case "history_query":
        text = historyQueryText(
            metricRaw: arguments["metric"]?.stringValue ?? "",
            rangeRaw: arguments["range"]?.stringValue ?? "",
            breakdownID: arguments["breakdown"]?.stringValue
        )
    default:
        return .init(content: [.text(text: "未知工具 \(params.name)")], isError: true)
    }
    return .init(content: [.text(text: text)], isError: false)
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
