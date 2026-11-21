import Foundation
import GRDB

// 日聚合器 + 多源合并策略——自 AgentUsageModel 拆出(solid-split,纯搬运)。

// MARK: - 聚合器

/// 样本 → 按 `(day, source, origin)` 的账本行;本地时区分天。Claude 侧按
/// `fileKey + message.id` 去重(stream 多行只计一次);id 缺失如实计不去重。
public struct AgentDailyAggregator {
    /// 累加桶(行模型字段平铺;day 为聚合键的一部分)。
    private struct Bucket {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var reasoning = 0
        var total = 0
        var requests = 0
    }

    private var buckets: [Key: Bucket] = [:]
    /// 项目轨(agent-tab/04):与合计轨同喂双写;cache 回填只进合计轨。
    private var projectBuckets: [ProjectKey: Bucket] = [:]
    /// 模型轨(agent-tab/05):挂在项目轨之下(项目 + 模型都归组成功才进)。
    private var modelBuckets: [ModelKey: Bucket] = [:]
    private var seenClaudeMessageIDs: Set<String> = []
    /// 非 static(DateFormatter 非并发安全,实例持有;聚合器本身单线程使用)。
    private let dayFormatter: DateFormatter

    private struct Key: Hashable {
        var day: String
        var source: AgentUsageSource
        var origin: AgentUsageOrigin
    }

    private struct ProjectKey: Hashable {
        var day: String
        var source: AgentUsageSource
        var project: String
    }

    private struct ModelKey: Hashable {
        var day: String
        var source: AgentUsageSource
        var project: String
        var model: String
    }

    public init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter = formatter
    }

    /// 归一化并聚合一条 ZCode 行;时间锚解析失败的行跳过。日键按本地时区。
    public mutating func addZCode(_ sample: ZCodeUsageSample, legacySchema: Bool) {
        let normalized = ZCodeTokenNormalization.normalize(
            input: sample.inputTokens,
            output: sample.outputTokens,
            cacheRead: sample.cacheReadTokens,
            cacheWrite: sample.cacheWriteTokens,
            reasoning: sample.reasoningTokens,
            computedTotal: sample.computedTotalTokens,
            legacySchema: legacySchema
        )
        guard normalized.total > 0,
              let anchorMs = ZCodeTokenNormalization.anchorTimestampMs(
                  startedAt: sample.startedAtMs,
                  completedAt: sample.completedAtMs,
                  durationMs: sample.durationMs.map { Int64($0) }
              ),
              let day = day(forMillis: anchorMs)
        else { return }

        let key = Key(day: day, source: .zcode, origin: .db)
        accumulate(into: &buckets[key, default: Bucket()], normalized: normalized)
        // 项目轨:workspace 归组失败(legacy 无 join / 路径退化)只进合计轨。
        if let project = sample.workspacePath.flatMap(AgentWorkspaceResolution.projectName(fromPath:)) {
            let projectKey = ProjectKey(day: day, source: .zcode, project: project)
            accumulate(into: &projectBuckets[projectKey, default: Bucket()], normalized: normalized)
            // 模型轨:项目归组成功且带模型标识才进(agent-tab/05)。
            if let model = sample.modelId, !model.isEmpty {
                let modelKey = ModelKey(day: day, source: .zcode, project: project, model: model)
                accumulate(into: &modelBuckets[modelKey, default: Bucket()], normalized: normalized)
            }
        }
    }

    /// 聚合一条 Claude 样本;重复 message.id 只计一次——msg id 是 Anthropic 消息
    /// 级全局标识,resume/compact 把历史复制进新文件时同 id 不双计。
    /// id 缺失如实计不去重。`slug` = 会话 jsonl 所在 projects 子目录名,归组
    /// 项目轨用(agent-tab/04)。
    public mutating func addClaude(_ sample: ClaudeUsageSample, slug: String? = nil) {
        let total = sample.inputTokens + sample.outputTokens
            + sample.cacheReadTokens + sample.cacheWriteTokens
        guard total > 0,
              let day = day(forMillis: sample.timestampMs)
        else { return }

        if let messageId = sample.messageId {
            guard !seenClaudeMessageIDs.contains(messageId) else { return }
            seenClaudeMessageIDs.insert(messageId)
        }

        let key = Key(day: day, source: .claude, origin: .jsonl)
        // Claude 五桶天然互斥,归一化形状直通(reasoning 恒 0——output 已含 thinking)。
        let normalized = (
            netInput: sample.inputTokens,
            netOutput: sample.outputTokens,
            cacheRead: sample.cacheReadTokens,
            cacheWrite: sample.cacheWriteTokens,
            reasoning: 0,
            total: total
        )
        accumulate(into: &buckets[key, default: Bucket()], normalized: normalized)

        if let project = sample.cwd.flatMap(AgentWorkspaceResolution.projectName(fromPath:))
            ?? slug.flatMap(AgentWorkspaceResolution.projectName(fromSlug:)) {
            let projectKey = ProjectKey(day: day, source: .claude, project: project)
            accumulate(into: &projectBuckets[projectKey, default: Bucket()], normalized: normalized)
            // 模型轨:项目归组成功且行带 message.model 才进(agent-tab/05)。
            if let model = sample.model, !model.isEmpty {
                let modelKey = ModelKey(day: day, source: .claude, project: project, model: model)
                accumulate(into: &modelBuckets[modelKey, default: Bucket()], normalized: normalized)
            }
        }
    }

    /// stats-cache 回填天(只有 total;day 字符串原样入桶)。
    public mutating func addStatsCacheDay(_ day: String, totalTokens: Int) {
        guard totalTokens > 0 else { return }
        let key = Key(day: day, source: .claude, origin: .cache)
        buckets[key, default: Bucket()].total += totalTokens
    }

    /// 输出账本行(按天排序;`scannedAt` 统一盖当前时刻)。
    public func rows(scannedAt: Date) -> [AgentDailyUsageRow] {
        let stamp = Int64(scannedAt.timeIntervalSince1970)
        return buckets
            .map { key, bucket in
                AgentDailyUsageRow(
                    day: key.day,
                    source: key.source,
                    origin: key.origin,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    cacheReadTokens: bucket.cacheRead,
                    cacheWriteTokens: bucket.cacheWrite,
                    reasoningTokens: bucket.reasoning,
                    totalTokens: bucket.total,
                    requestCount: bucket.requests,
                    scannedAt: stamp
                )
            }
            .sorted { ($0.day, $0.source.rawValue) < ($1.day, $1.source.rawValue) }
    }

    /// 是否已聚合到任何行(编排器判断「今天有没有数据」用)。
    public var isEmpty: Bool {
        buckets.isEmpty
    }

    /// 项目轨行(按天、来源、项目排序;`scannedAt` 统一盖当前时刻)。
    public func projectRows(scannedAt: Date) -> [AgentProjectUsageRow] {
        let stamp = Int64(scannedAt.timeIntervalSince1970)
        return projectBuckets
            .map { key, bucket in
                AgentProjectUsageRow(
                    day: key.day,
                    source: key.source,
                    project: key.project,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    cacheReadTokens: bucket.cacheRead,
                    cacheWriteTokens: bucket.cacheWrite,
                    reasoningTokens: bucket.reasoning,
                    totalTokens: bucket.total,
                    requestCount: bucket.requests,
                    scannedAt: stamp
                )
            }
            .sorted { ($0.day, $0.source.rawValue, $0.project) < ($1.day, $1.source.rawValue, $1.project) }
    }

    /// 模型轨行(按天、来源、项目、模型排序;`scannedAt` 统一盖当前时刻)。
    public func modelRows(scannedAt: Date) -> [AgentModelUsageRow] {
        let stamp = Int64(scannedAt.timeIntervalSince1970)
        return modelBuckets
            .map { key, bucket in
                AgentModelUsageRow(
                    day: key.day,
                    source: key.source,
                    project: key.project,
                    model: key.model,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    cacheReadTokens: bucket.cacheRead,
                    cacheWriteTokens: bucket.cacheWrite,
                    reasoningTokens: bucket.reasoning,
                    totalTokens: bucket.total,
                    requestCount: bucket.requests,
                    scannedAt: stamp
                )
            }
            .sorted { ($0.day, $0.source.rawValue, $0.project, $0.model) < (
                $1.day,
                $1.source.rawValue,
                $1.project,
                $1.model
            ) }
    }

    private func accumulate(
        into bucket: inout Bucket,
        normalized: (netInput: Int, netOutput: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, total: Int)
    ) {
        bucket.input += normalized.netInput
        bucket.output += normalized.netOutput
        bucket.cacheRead += normalized.cacheRead
        bucket.cacheWrite += normalized.cacheWrite
        bucket.reasoning += normalized.reasoning
        bucket.total += normalized.total
        bucket.requests += 1
    }

    /// 毫秒时间戳 → 本地时区日键(dayFormatter 默认系统时区)。
    private func day(forMillis ms: Int64) -> String? {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return dayFormatter.string(from: date)
    }
}

// MARK: - 合并策略

/// 扫描结果与库中已有行的合并:细粒度(jsonl / db)永远覆盖写;cache 只填
/// 「库中无该天 claude 行且非今天」的缺口(今天的 cache 数据可能还没被 Claude
/// 算出来,宁缺勿错)。
public enum AgentUsageMerge {
    /// - Parameters:
    ///   - freshDetailed: 本轮扫出的细粒度行(origin = jsonl / db)。
    ///   - cacheBackfill: stats-cache 粗粒度行(origin = cache)。
    ///   - knownClaudeDays: 库中已有 claude 行的天(任何 origin)。
    ///   - today: 今天日键;cache 不回填今天。
    public static func merge(
        freshDetailed: [AgentDailyUsageRow],
        cacheBackfill: [AgentDailyUsageRow],
        knownClaudeDays: Set<String>,
        today: String
    ) -> (upserts: [AgentDailyUsageRow], insertsIfAbsent: [AgentDailyUsageRow]) {
        let upserts = freshDetailed
        let inserts = cacheBackfill.filter { row in
            row.day != today && !knownClaudeDays.contains(row.day)
        }
        return (upserts, inserts)
    }
}
