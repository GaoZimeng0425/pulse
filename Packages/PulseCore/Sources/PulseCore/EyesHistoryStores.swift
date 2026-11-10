import Foundation
import GRDB

// MARK: - mcp-eyes 写侧 store(mcp-eyes/02)

//
// 同 CleanHistoryStore 样板:actor 包 DatabaseQueue,与采样历史共用同一库
// 文件与队列纪律。读侧不走这里——McpEyesQuery 直查(单测与 pulse-mcp 同一
// 把钥匙),口径不双写。

/// 告警历史:AlertCenter 触发时记一笔(fire-and-forget,触发稀疏、乱序无害;
/// 同秒同主体 REPLACE 天然去重)。
public actor AlertEventStore {
    private let database: DatabaseQueue

    public init(database: DatabaseQueue) {
        self.database = database
    }

    public func record(_ occurrence: AlertOccurrence) throws {
        try database.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO alert_event (ts, kind, subject_key, subject_name, value)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    Int(occurrence.firedAt.timeIntervalSince1970),
                    occurrence.kind.rawValue,
                    occurrence.subjectKey,
                    occurrence.subjectName,
                    occurrence.value,
                ]
            )
        }
    }
}

/// dev server 状态:HistoryFeature 消费每轮 `.devServers` 广播入串行写流,
/// 本 store 内部**分钟节流**——同分钟且 pid 集未变不重写(事件 1s 一轮,库
/// 粒度是分钟);退出进程超 10 分钟清尸(读侧年龄口径与之一致)。
public actor DevServerStateStore {
    private let database: DatabaseQueue
    private var lastWrittenMinute = -1
    private var lastPIDSet: Set<pid_t> = []

    public init(database: DatabaseQueue) {
        self.database = database
    }

    public func upsert(_ states: [DevServerStatus], now: Date) throws {
        let minute = Int(now.timeIntervalSince1970) / 60
        let pids = Set(states.map(\.pid))
        if minute == lastWrittenMinute, pids == lastPIDSet {
            return
        }
        lastWrittenMinute = minute
        lastPIDSet = pids

        try database.write { db in
            let nowSeconds = Int(now.timeIntervalSince1970)
            for state in states {
                try db.execute(
                    sql: """
                    INSERT INTO dev_server_state (
                        pid, kind, name, memory_bytes, idle_seconds, ports, first_seen, last_seen
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(pid) DO UPDATE SET
                        kind = excluded.kind,
                        name = excluded.name,
                        memory_bytes = excluded.memory_bytes,
                        idle_seconds = excluded.idle_seconds,
                        ports = excluded.ports,
                        last_seen = excluded.last_seen
                    """,
                    arguments: [
                        Int(state.pid),
                        state.kind.rawValue,
                        state.displayName,
                        Int(state.memoryBytes),
                        state.idleSeconds,
                        state.listeningPorts.map(String.init).joined(separator: ","),
                        nowSeconds,
                        nowSeconds,
                    ]
                )
            }
            // 清尸:最后见到超 10 分钟的行删掉(集合为空时所有行都会随年龄出局)。
            try db.execute(
                sql: "DELETE FROM dev_server_state WHERE last_seen < ?",
                arguments: [nowSeconds - 600]
            )
        }
    }
}
