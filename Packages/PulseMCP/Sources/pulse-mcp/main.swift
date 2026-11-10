// pulse-mcp —— Pulse 的 MCP stdio server(p3-root-mcp/02;mcp-clean/02 扩清理)。
// 读 Pulse 历史库(WAL 只读)回答:谁在吃 CPU / 当前读数 / 历史趋势;
// app 不在跑也能答(分钟级落库数据,年龄如实标注)。
// mcp-clean:list_cleanable / clean 经本机回环 IPC 交给在跑的 app——只碰
// 「可安全清理」档,执行前用户会在 Pulse 确认单上亲手点一次。
// 分发:嵌 Pulse.app/Contents/MacOS/,AI 客户端以 stdio 方式拉起本可执行。
import Foundation
import MCP
import PulseCore

let server = Server(
    name: "pulse",
    version: "0.3.0",
    instructions: """
    Pulse 菜单栏系统监视器的数据查询。数据为分钟级采样落库(非实时流),\
    每个答案都会标注数据年龄;Pulse app 未运行时仍可回答(回退最近落库)。\
    清理类工具(list_cleanable / clean)要求 Pulse app 正在运行:AI 只能碰\
    「可安全清理」档,真正的删除由用户在 Pulse 确认单上确认后执行。\
    诊断类工具(why_cpu_high / why_memory_high / top_disk_io / process_info /\
    recent_alerts / list_dev_servers)答历史与档案,不含此刻实时值。
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
                    "内存(全部应用·当分钟峰值合计,含压缩可超物理内存):\(PulseFormat.memory(UInt64(max(0, memory.value))))(\(ageText(atSeconds: memory.atSeconds, now: now)))"
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

// MARK: - mcp-clean IPC 客户端(mcp-clean/02)

//
// 经 127.0.0.1 + 令牌找在跑的 Pulse app:端点文件 ~/.Pulse/mcp-clean.json
// (0600)。app 没跑/接口未就绪 = 如实报,不降级不猜。文案单出处
// PulseCore McpCleanText,这里只接线。

private func cleanEndpoint() -> McpCleanEndpoint? {
    let directory = URL(
        fileURLWithPath: NSString(string: "~/.Pulse").expandingTildeInPath,
        isDirectory: true
    )
    guard let endpoint = McpCleanEndpoint.load(at: McpCleanEndpoint.url(directory: directory)) else {
        return nil
    }
    // pid 已死而端点文件还在(app 被强杀没走到退出清理)= app 不在。
    if kill(endpoint.pid, 0) != 0, errno == ESRCH {
        return nil
    }
    return endpoint
}

/// 同步 HTTP(工具处理器是同步闭包;clean 等用户确认最长 10 分钟,同步等)。
private func cleanIPC(
    path: String,
    method: String,
    body: Data? = nil,
    timeoutSeconds: TimeInterval
) -> (status: Int, data: Data)? {
    guard let endpoint = cleanEndpoint(),
          let url = URL(string: "http://127.0.0.1:\(endpoint.port)\(path)")
    else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeoutSeconds
    request.setValue(endpoint.token, forHTTPHeaderField: "X-Pulse-Token")
    if let body {
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    var result: (Int, Data)?
    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        if let http = response as? HTTPURLResponse {
            result = (http.statusCode, data ?? Data())
        }
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + timeoutSeconds + 5)
    return result
}

private func listCleanableText() -> String {
    guard let (status, data) = cleanIPC(path: "/cleanable", method: "GET", timeoutSeconds: 30) else {
        return "Pulse app 未运行(或 AI 清理接口未就绪)——list_cleanable / clean 都需要 Pulse 在跑。"
    }
    guard status == 200,
          let list = try? JSONDecoder().decode(McpCleanableListResponse.self, from: data)
    else {
        return "查询失败(HTTP \(status))。"
    }
    return McpCleanText.cleanableList(list)
}

private func cleanText(paths: [String]) -> String {
    guard !paths.isEmpty else {
        return "没有给要清理的路径——先用 list_cleanable 拿清单,把要清的 path 原样传进来。"
    }
    guard let body = try? JSONEncoder().encode(McpCleanRequest(paths: paths)) else {
        return "请求编码失败。"
    }
    guard let (status, data) = cleanIPC(
        path: "/clean", method: "POST", body: body, timeoutSeconds: 610
    ) else {
        return "Pulse app 未运行(或连接失败)——清理需要 Pulse 在跑。"
    }
    guard status == 200,
          let response = try? JSONDecoder().decode(McpCleanRunResponse.self, from: data)
    else {
        return "清理请求失败(HTTP \(status))。"
    }
    return McpCleanText.cleanResult(response)
}

// MARK: - mcp-eyes 取数与文案(文案单出处 McpEyesText,这里只接线)

private func whyMemoryHighText(topN: Int, lookbackMinutes: Int) -> String {
    withDatabase { db, now in
        let top = try InsightQuery.topMemoryGroups(
            limit: topN, lookbackMinutes: lookbackMinutes, now: now, in: db
        )
        let snapshot = try InsightQuery.latestSnapshot(now: now, in: db)
        return McpEyesText.memoryRanking(
            top, systemMemory: snapshot.memoryBytes, lookbackMinutes: lookbackMinutes, now: now
        )
    }
}

private func topDiskIoText(topN: Int, lookbackMinutes: Int) -> String {
    withDatabase { db, now in
        let top = try InsightQuery.topDiskGroups(
            limit: topN, lookbackMinutes: lookbackMinutes, now: now, in: db
        )
        return McpEyesText.diskRanking(top, lookbackMinutes: lookbackMinutes, now: now)
    }
}

private func processInfoText(query rawQuery: String) -> String {
    let trimmed = rawQuery.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
        return "没给查询词——传 pid(纯数字)或可执行路径/命令行/工作目录的子串。"
    }
    let pid = Int(trimmed)
    let substring = pid == nil ? trimmed : nil
    return withDatabase { db, now in
        let rows = try InsightQuery.lineageMatches(pid: pid, substring: substring, in: db)
        // 活性现探(出生登记 ≠ 存活):kill 探针,EPERM = 存在但非本用户可查。
        var alive: [Int: Bool] = [:]
        for row in rows where row.pid > 0 {
            let result = kill(pid_t(row.pid), 0)
            alive[row.pid] = result == 0 || (result != 0 && errno != ESRCH)
        }
        return McpEyesText.processProfiles(rows, alive: alive, now: now)
    }
}

private func recentAlertsText(hours: Int) -> String {
    withDatabase { db, now in
        let rows = try McpEyesQuery.recentAlerts(hours: hours, now: now, in: db)
        return McpEyesText.alertHistory(rows, now: now)
    }
}

private func listDevServersText() -> String {
    withDatabase { db, now in
        let rows = try McpEyesQuery.devServers(in: db)
        return McpEyesText.devServers(rows, now: now)
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
        Tool(
            name: "list_cleanable",
            description: "列出当前「可安全清理」的项(路径/大小/多久未动/数据年龄)。只含安全档且此刻不在用的项;「先检查」档不出现,须用户在 app 里手勾。需要 Pulse app 正在运行。",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        Tool(
            name: "clean",
            description: "把选中的可清理路径提交给 Pulse 执行:app 会弹出确认单,用户点「移入废纸篓」后才真删(全部进废纸篓可找回;10 分钟无人确认自动撤单),随后返回逐项结果。只接受安全档且非在用的路径——先用 list_cleanable 拿路径。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "paths": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("要清理的完整路径列表(来自 list_cleanable 的输出)"),
                    ]),
                ]),
                "required": .array([.string("paths")]),
            ])
        ),
        Tool(
            name: "why_memory_high",
            description: "回答\"为什么内存紧\":最近时间窗内内存最高的应用排行(当分钟峰值口径,均值+峰值,含项目归属),附全部应用内存合计与数据年龄。",
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
            name: "top_disk_io",
            description: "最近时间窗内磁盘读写总量最高的应用排行(读/写分开列,含项目归属);部分分钟缺磁盘账时如实标注。",
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
            name: "process_info",
            description: "查进程档案:按 pid(纯数字)或可执行路径/命令行/工作目录的子串查,返回父进程、可执行路径、工作目录、完整命令行、首见时刻,并对每个 pid 做存活探针。档案是出生登记(Pulse 运行期间见过即留),刚启动的进程查不到。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("pid 或子串(路径/命令行/工作目录任一命中)"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        Tool(
            name: "recent_alerts",
            description: "最近 N 小时的告警历史(同主体聚合:最近触发时刻/读数/次数)。涵盖 CPU 负载、组 CPU、新组内存、磁盘可用、dev server 闲置。落盘从 Pulse 装上本版本起累积,更早的没有留档。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "hours": .object([
                        "type": .string("integer"),
                        "description": .string("回看小时数,默认 24"),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "list_dev_servers",
            description: "本机 dev server(本地开发常驻服务,如 vite/next dev)盘点:种类/闲置时长/监听端口/内存/最后见到时刻;久未见到的如实标\"可能已退出\"。",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
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
    case "list_cleanable":
        text = listCleanableText()
    case "clean":
        // paths 兼容数组与单字符串两种传法(客户端拼参数习惯不一)。
        var paths: [String] = []
        switch arguments["paths"] {
        case let .array(values):
            paths = values.compactMap(\.stringValue)
        case let .string(single):
            paths = [single]
        default:
            break
        }
        text = cleanText(paths: paths)
    case "why_memory_high":
        let topN = arguments["top_n"]?.intValue ?? 5
        let lookback = arguments["lookback_minutes"]?.intValue ?? 10
        text = whyMemoryHighText(
            topN: max(1, min(20, topN)), lookbackMinutes: max(1, min(1440, lookback))
        )
    case "top_disk_io":
        let topN = arguments["top_n"]?.intValue ?? 5
        let lookback = arguments["lookback_minutes"]?.intValue ?? 10
        text = topDiskIoText(
            topN: max(1, min(20, topN)), lookbackMinutes: max(1, min(1440, lookback))
        )
    case "process_info":
        text = processInfoText(query: arguments["query"]?.stringValue ?? "")
    case "recent_alerts":
        let hours = arguments["hours"]?.intValue ?? 24
        text = recentAlertsText(hours: max(1, min(24 * 30, hours)))
    case "list_dev_servers":
        text = listDevServersText()
    default:
        return .init(content: [.text(text: "未知工具 \(params.name)")], isError: true)
    }
    return .init(content: [.text(text: text)], isError: false)
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
