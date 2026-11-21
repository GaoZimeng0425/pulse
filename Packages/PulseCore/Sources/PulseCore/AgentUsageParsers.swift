import Foundation
import GRDB

// ZCode 归一化 + Claude 行解析 + stats-cache 解析——自 AgentUsageModel 拆出(solid-split,纯搬运)。

// MARK: - ZCode 归一化(tokscale zcode.rs 同款)

/// 五桶重叠扣除与时间锚定。input/output 的含重叠形状由 `computedTotalTokens`
/// 检测:total == input+output(而非全加和)即含重叠,把重叠从 input/output
/// 减掉;检测不出形状(无 total)按 schema 新旧区分处理。
public enum ZCodeTokenNormalization {
    /// 饱和减法:overlap 钳在 value 内,不落负。
    static func subtractOverlap(_ value: Int, _ overlap: Int) -> Int {
        let value = max(value, 0)
        let overlap = max(overlap, 0)
        return value - min(overlap, value)
    }

    /// 归一化为互斥五桶 + 总和。
    /// - computedTotal 在且形状=含重叠 → 减重叠;
    /// - computedTotal 缺失 + legacy schema → 无条件减(旧库行实测均含重叠);
    /// - computedTotal 缺失 + 新 schema → 形状未知,原样透传(宁少勿错加)。
    public static func normalize(
        input: Int?,
        output: Int?,
        cacheRead: Int?,
        cacheWrite: Int?,
        reasoning: Int?,
        computedTotal: Int?,
        legacySchema: Bool
    ) -> (netInput: Int, netOutput: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, total: Int) {
        let rawInput = max(input ?? 0, 0)
        let rawOutput = max(output ?? 0, 0)
        let cacheRead = max(cacheRead ?? 0, 0)
        let cacheWrite = max(cacheWrite ?? 0, 0)
        let reasoning = max(reasoning ?? 0, 0)
        let cacheOverlap = cacheRead + cacheWrite

        var netInput = rawInput
        var netOutput = rawOutput
        if let total = computedTotal.map({ max($0, 0) }) {
            let inclusiveTotal = rawInput + rawOutput
            let exclusiveTotal = inclusiveTotal + cacheOverlap + reasoning
            if cacheOverlap > 0 || reasoning > 0, total == inclusiveTotal, total != exclusiveTotal {
                netInput = subtractOverlap(rawInput, cacheOverlap)
                netOutput = subtractOverlap(rawOutput, reasoning)
            }
        } else if legacySchema {
            netInput = subtractOverlap(rawInput, cacheOverlap)
            netOutput = subtractOverlap(rawOutput, reasoning)
        }

        let total = netInput + netOutput + cacheRead + cacheWrite + reasoning
        return (netInput, netOutput, cacheRead, cacheWrite, reasoning, total)
    }

    /// 时间锚:started_at 优先;缺失时 completed_at - duration 回推(防幻影
    /// 前向投影);都缺返回 nil(该行无法归天,调用方跳过)。
    public static func anchorTimestampMs(
        startedAt: Int64?,
        completedAt: Int64?,
        durationMs: Int64?
    ) -> Int64? {
        if let started = startedAt, started > 0 {
            return started
        }
        guard let completed = completedAt, completed > 0 else { return nil }
        if let duration = durationMs, duration > 0 {
            let back = completed - duration
            if back > 0 {
                return back
            }
        }
        return completed
    }
}

// MARK: - Claude 行解析

/// projects jsonl 单行 → usage 样本。只认 assistant 行且 `message.usage` 五项
/// 非全零;user / tool / 半行安静返回 nil。timestamp 顶层 ISO8601,缺失跳过。
public enum ClaudeTranscriptUsageParser {
    /// 一行(已 trim);解析不出样本返回 nil。`"assistant"` 字面量预筛在 JSON
    /// 之前——真 assistant 行必含该字面量(type 值),2.9GB 全量重扫时跳过
    /// ~七成非 assistant 行的整行 JSON 解析(2026-11-18「重新扫描」卡顿实案,
    /// 负载 60+ 下解析是主耗时);后续 JSON 判断仍是权威,误筛进来的行照旧 nil。
    public static func parse(line: String) -> ClaudeUsageSample? {
        guard line.hasPrefix("{"),
              line.contains("\"assistant\""),
              let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (record["type"] as? String) == "assistant",
              let message = record["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let input = usage["input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        guard input + cacheRead + cacheWrite + output > 0,
              let timestamp = (record["timestamp"] as? String).flatMap(AgentISO8601.parse)
        else { return nil }

        let messageId = message["id"] as? String
        return ClaudeUsageSample(
            timestampMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            messageId: (messageId?.isEmpty == false) ? messageId : nil,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            cwd: (record["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            model: (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: - stats-cache 解析

/// `~/.claude/stats-cache.json` 的 `dailyModelTokens`(实测 2026-11-12:
/// `[{date: "2026-08-01", tokensByModel: {model: tokens}}]`)。只有按天 total,
/// 是 jsonl 30 天窗口外的兜底回填源;新鲜度由 Claude 自算不受控
/// (lastComputedDate 实测停 11-04)。
public enum ClaudeStatsCacheParser {
    /// 按天 token 总量(各模型求和);形状不符返回空。
    public static func dailyTotals(from data: Data?) -> [(day: String, totalTokens: Int)] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["dailyModelTokens"] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let day = entry["date"] as? String,
                  let byModel = entry["tokensByModel"] as? [String: Int]
            else { return nil }
            let total = byModel.values.reduce(0, +)
            guard total > 0 else { return nil }
            return (day, total)
        }
    }
}
