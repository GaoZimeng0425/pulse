import Foundation
import GRDB

// MARK: - 清理历史(p4-cleaner/04;GLOSSARY「清理历史」)

//
// 现有 GRDB 历史库加两张表(迁移 `p4-cleaner-04-clean-history`,见 HistoryDatabase):
//   clean_run  —— 一次清理一行:起止时刻 / 项数 / 释放字节 / 失败项数;
//   clean_item —— 逐项一行:路径 / 标题 / 字节 / 档位 / 规则 / 去向(废纸篓内路径)或失败原因。
// 永久保留、无自动清理(ADR-0008:事后追溯的唯一记录)。写与读都走 DatabaseQueue
// (GRDB 串行化),actor 只是给 Swift 6 一个干净的隔离域;与采样历史的 HistoryEngine
// 共用同一个库文件、同一个队列对象。

/// 一次清理(列表行)。
public struct CleanRunRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let startedAt: Date
    public let finishedAt: Date
    public let itemCount: Int
    public let freedBytes: Int64
    public let failedCount: Int

    public init(id: Int64, startedAt: Date, finishedAt: Date, itemCount: Int, freedBytes: Int64, failedCount: Int) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.itemCount = itemCount
        self.freedBytes = freedBytes
        self.failedCount = failedCount
    }
}

/// 一次清理里的一项(明细行)。
public struct CleanItemRecord: Sendable, Equatable, Identifiable {
    public var id: String { "\(runID):\(path)" }

    public let runID: Int64
    public let path: String
    public let title: String
    public let bytes: Int64
    public let tier: CleanSafetyTier
    public let ruleID: String
    public let outcome: CleanItemOutcome

    public init(runID: Int64, path: String, title: String, bytes: Int64, tier: CleanSafetyTier, ruleID: String, outcome: CleanItemOutcome) {
        self.runID = runID
        self.path = path
        self.title = title
        self.bytes = bytes
        self.tier = tier
        self.ruleID = ruleID
        self.outcome = outcome
    }
}

public actor CleanHistoryStore {
    private let database: DatabaseQueue

    public init(database: DatabaseQueue) {
        self.database = database
    }

    /// 落一次清理:run 一行 + item 多行,同一事务。返回 run id。
    /// 空报告(计划为空)不落库——没发生清理就没有历史。
    @discardableResult
    public func record(_ report: CleanRunReport) throws -> Int64? {
        guard !report.items.isEmpty else { return nil }
        return try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO clean_run (started_at, finished_at, item_count, freed_bytes, failed_count)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    HistoryWindows.epochSeconds(of: report.startedAt),
                    HistoryWindows.epochSeconds(of: report.finishedAt),
                    report.items.count,
                    report.freedBytes,
                    report.failed.count,
                ]
            )
            let runID = db.lastInsertedRowID
            for item in report.items {
                let destination: String?
                let failure: String?
                switch item.outcome {
                case let .recycled(path):
                    destination = path
                    failure = nil
                case let .failed(reason):
                    destination = nil
                    failure = reason
                }
                try db.execute(
                    sql: """
                    INSERT INTO clean_item (run_id, path, title, bytes, tier, rule_id, destination, failure)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [runID, item.path, item.title, item.bytes, item.tier.rawValue, item.ruleID, destination, failure]
                )
            }
            return runID
        }
    }

    /// 最近的清理,新的在前。
    public func runs(limit: Int = 100) throws -> [CleanRunRecord] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, started_at, finished_at, item_count, freed_bytes, failed_count
                FROM clean_run ORDER BY started_at DESC, id DESC LIMIT ?
                """,
                arguments: [limit]
            ).map { row in
                CleanRunRecord(
                    id: row["id"],
                    startedAt: Date(timeIntervalSince1970: TimeInterval(row["started_at"] as Int)),
                    finishedAt: Date(timeIntervalSince1970: TimeInterval(row["finished_at"] as Int)),
                    itemCount: row["item_count"],
                    freedBytes: row["freed_bytes"],
                    failedCount: row["failed_count"]
                )
            }
        }
    }

    /// 某次清理的逐项明细,按落库顺序(= 确认清单顺序)。
    public func items(runID: Int64) throws -> [CleanItemRecord] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT run_id, path, title, bytes, tier, rule_id, destination, failure
                FROM clean_item WHERE run_id = ? ORDER BY rowid
                """,
                arguments: [runID]
            ).map { row in
                let destination: String? = row["destination"]
                let failure: String? = row["failure"]
                let outcome: CleanItemOutcome = if let destination {
                    .recycled(destination: destination)
                } else {
                    // 库里 destination 与 failure 都空只可能是外部改库;如实报"原因未知",不装成功。
                    .failed(reason: failure ?? "原因未记录")
                }
                return CleanItemRecord(
                    runID: row["run_id"],
                    path: row["path"],
                    title: row["title"],
                    bytes: row["bytes"],
                    tier: CleanSafetyTier(rawValue: row["tier"]) ?? .checkFirst,
                    ruleID: row["rule_id"],
                    outcome: outcome
                )
            }
        }
    }
}
