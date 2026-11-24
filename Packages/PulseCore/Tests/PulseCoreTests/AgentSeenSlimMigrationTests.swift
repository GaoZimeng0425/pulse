import GRDB
@testable import PulseCore
import XCTest

// MARK: - 消息去重表瘦身(agent-tab/13)

/// 造 agent-tab/12 结构的旧库(每行带 file_key 全路径 + day),跑瘦身迁移,断言:
/// ①全局 id 集与按文件取 id 与迁移前一致;②旧冗余列消失;③purgeFile 不留孤儿;
/// ④新结构下 replace 照常去重入库。
final class AgentSeenSlimMigrationTests: XCTestCase {
    private func makeLegacyDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try HistoryDatabase.migrator().migrate(queue, upTo: HistoryDatabase.agentCheckpointMigrationID)
        try queue.write { db in
            let rows: [(String, String, String)] = [
                ("m1", "proj-a/s1.jsonl", "2026-11-01"),
                ("m2", "proj-a/s1.jsonl", "2026-11-01"),
                ("m3", "proj-b/s2.jsonl", "2026-11-02"),
            ]
            for (id, file, day) in rows {
                try db.execute(
                    sql: "INSERT INTO agent_seen_messages (message_id, file_key, day) VALUES (?, ?, ?)",
                    arguments: [id, file, day]
                )
            }
        }
        return queue
    }

    func testMigrationPreservesIDsPerFile() throws {
        let queue = try makeLegacyDatabase()
        try HistoryDatabase.migrator().migrate(queue)
        let store = AgentCheckpointStore(database: queue)

        XCTAssertEqual(try store.loadSeenMessageIDs(), ["m1", "m2", "m3"])
        XCTAssertEqual(try Set(store.seenMessageIDs(fileKey: "proj-a/s1.jsonl")), ["m1", "m2"])
        XCTAssertEqual(try store.seenMessageIDs(fileKey: "proj-b/s2.jsonl"), ["m3"])
    }

    func testMigrationDropsRedundantColumns() throws {
        let queue = try makeLegacyDatabase()
        try HistoryDatabase.migrator().migrate(queue)
        let columns = try queue.read { db in
            try db.columns(in: "agent_seen_messages").map(\.name)
        }
        XCTAssertEqual(Set(columns), ["message_id", "file_id"])
        let fileCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_seen_files")
        }
        XCTAssertEqual(fileCount, 2)
    }

    func testPurgeFileLeavesNoOrphans() throws {
        let queue = try makeLegacyDatabase()
        try HistoryDatabase.migrator().migrate(queue)
        let store = AgentCheckpointStore(database: queue)

        try store.purgeFile(fileKey: "proj-a/s1.jsonl")

        XCTAssertEqual(try store.loadSeenMessageIDs(), ["m3"])
        let files = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT file_key FROM agent_seen_files")
        }
        XCTAssertEqual(files, ["proj-b/s2.jsonl"])
    }

    /// 文件库:旧结构灌入 2 万行长路径 → 走 `open(at:)` 迁移 → 文件变小(VACUUM 生效),
    /// 且 id 一条不丢。
    func testOpenShrinksLegacyFileDatabase() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seen-slim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite")

        let count = 20000
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try HistoryDatabase.migrator().migrate(legacy, upTo: HistoryDatabase.agentCheckpointMigrationID)
            try legacy.write { db in
                let longPrefix = String(repeating: "-Users-someone-Documents-project-worktrees-x", count: 2)
                for index in 0 ..< count {
                    try db.execute(
                        sql: "INSERT INTO agent_seen_messages (message_id, file_key, day) VALUES (?, ?, ?)",
                        arguments: ["msg_\(index)", "\(longPrefix)/\(index % 50).jsonl", "2026-11-01"]
                    )
                }
            }
            try legacy.close()
        }
        let before = try fileSize(url)

        let queue = try HistoryDatabase.open(at: url)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        XCTAssertEqual(try AgentCheckpointStore(database: queue).loadSeenMessageIDs().count, count)
        try queue.close()

        XCTAssertLessThan(try fileSize(url), before / 2)
    }

    private func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    func testReplaceRegistersFileAndIgnoresDuplicates() throws {
        let queue = try HistoryDatabase.openInMemory()
        let store = AgentCheckpointStore(database: queue)
        try store.replace(
            fileKey: "proj-a/s1.jsonl", consumedOffset: 10, prefixSha256: Data([1]),
            savedAtMtime: 1, savedAtSize: 10, buckets: [], newSeenMessageIDs: ["m1", "m2"]
        )
        // 第二次落同文件:文件行复用,已有 id 忽略。
        try store.replace(
            fileKey: "proj-a/s1.jsonl", consumedOffset: 20, prefixSha256: Data([2]),
            savedAtMtime: 2, savedAtSize: 20, buckets: [], newSeenMessageIDs: ["m2", "m3"]
        )
        XCTAssertEqual(try Set(store.seenMessageIDs(fileKey: "proj-a/s1.jsonl")), ["m1", "m2", "m3"])
        let fileCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_seen_files")
        }
        XCTAssertEqual(fileCount, 1)
    }
}
