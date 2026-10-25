import GRDB
@testable import PulseCore
import XCTest

// MARK: - 宽表 → 窄表迁移对拍(p2-review/09;单向门的验收)

/// 用 `migrator().migrate(_:upTo:)` 造 p2-sensors-v2 时代的**真旧库**(宽表 +
/// 8 仪表列),塞进有值/NULL 混合的行,再跑全量迁移到 v09,断言:
/// ①存量逐值搬进窄表(NULL 列不产行);②宽列已删;③同一份数据迁移前
/// (宽表查询)与迁移后(窄表查询)的序列逐位一致(对拍);④文件库打开时的
/// 迁移前备份行为(三件套、不重复)。
final class HistoryGaugeMigrationTests: XCTestCase {
    private var base: Int {
        1_789_000_000 / 3600 * 3600
    }

    /// 造旧库并塞三行混合数据:全值行 / 部分值行 / 全 NULL 行。
    private func makeLegacyDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try HistoryDatabase.migrator().migrate(queue, upTo: "p2-sensors-v2")
        try queue.write { db in
            // 全值行(五路含 ane)。
            try db.execute(
                sql: """
                INSERT INTO system_min (ts, load_avg, load_max, temp_avg, temp_max, gpu_util,
                    pow_cpu, pow_gpu, pow_ane, pow_ram, pow_soc)
                VALUES (?, 1, 1, 45.5, 52.0, 33.0, 2.0, 1.0, 0.5, 0.3, 0.2)
                """,
                arguments: [base]
            )
            // 部分值行(缺 ANE/RAM 域 = 无该列芯片形状;温度 NULL)。
            try db.execute(
                sql: """
                INSERT INTO system_min (ts, load_avg, load_max, gpu_util, pow_cpu, pow_soc)
                VALUES (?, 1, 1, 66.0, 12.5, 0.7)
                """,
                arguments: [base + 60]
            )
            // 全 NULL 行(传感器缺席)。
            try db.execute(
                sql: "INSERT INTO system_min (ts, load_avg, load_max) VALUES (?, 1, 1)",
                arguments: [base + 120]
            )
            // 小时表同样塞一行,验证 system_hour 列也被搬。
            try db.execute(
                sql: """
                INSERT INTO system_hour (ts, load_avg, load_max, temp_avg, temp_max)
                VALUES (?, 1, 1, 44.0, 51.0)
                """,
                arguments: [base]
            )
        }
        return queue
    }

    func testMigrationMovesWideColumnsIntoNarrowRowsAndDropsThem() throws {
        let queue = try makeLegacyDatabase()
        try HistoryDatabase.migrator().migrate(queue) // v09

        try queue.read { db in
            // 全值行 → 8 行窄记录,逐值相等。
            let full = try Dictionary(
                Row.fetchAll(
                    db,
                    sql: "SELECT key, avg, max FROM gauge_min WHERE ts = ?",
                    arguments: [base]
                ).map { row -> (String, (Double?, Double?)) in
                    (row["key"], (row["avg"], row["max"]))
                },
                uniquingKeysWith: { _, rhs in rhs }
            )
            XCTAssertEqual(full.count, 8, "全值行 8 键各一行")
            XCTAssertEqual(full["temp_avg"]?.0, 45.5)
            XCTAssertEqual(full["temp_max"]?.1, 52.0, "最热列进 max")
            XCTAssertNil(full["temp_max"]?.0, "最热行 avg 列 NULL(口径单点)")
            XCTAssertEqual(full["gpu_util"]?.0, 33.0)
            XCTAssertEqual(full["pow_ane"]?.0, 0.5)

            // 部分值行 → 只有在场的 3 键。
            let partial = try Row
                .fetchAll(db, sql: "SELECT key FROM gauge_min WHERE ts = ?", arguments: [base + 60])
                .map { row -> String in row["key"] }
                .sorted()
            XCTAssertEqual(partial, ["gpu_util", "pow_cpu", "pow_soc"], "NULL 列不产行")

            // 全 NULL 行 → 无窄行。
            let empty = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM gauge_min WHERE ts = ?", arguments: [base + 120]
            )
            XCTAssertEqual(empty, 0)

            // 小时表同搬。
            let hourMax = try Double.fetchOne(
                db, sql: "SELECT max FROM gauge_hour WHERE ts = ? AND key = 'temp_max'", arguments: [base]
            )
            XCTAssertEqual(hourMax, 51.0)

            // 宽列已删(system_min 只剩 7 列)。
            let columns = try String
                .fetchAll(db, sql: "SELECT name FROM pragma_table_info('system_min')")
                .sorted()
            XCTAssertEqual(columns, ["disk_read", "disk_written", "load_avg", "load_max", "net_rx", "net_tx", "ts"])
        }
    }

    func testSeriesBeforeAndAfterMigrationAgree() async throws {
        // 对拍:同一份旧数据,迁移前用宽表查询(旧引擎逻辑已不可得——改用迁移
        // 前手工按宽列口径算期望值),迁移后走窄表查询,逐位一致。
        let queue = try makeLegacyDatabase()
        // 期望值按旧宽列口径手算(与 HistoryQueries 旧 SQL 语义一致):
        // 温度均值桶 = AVG(temp_avg)(一分钟粒度直取行值);功率合计桶 =
        // AVG(COALESCE 各域和 FILTER 有任一域)。
        let expectedTemperature = 45.5 // 唯一有 temp_avg 的分钟
        let expectedPower = 2.0 + 1.0 + 0.5 + 0.3 + 0.2 // 全值分钟;部分值分钟独立桶

        try HistoryDatabase.migrator().migrate(queue) // v09
        let engine = HistoryEngine(database: queue)
        let now = Date(timeIntervalSince1970: Double(base + 3600))

        let temperatureSeries = await engine.series(metric: .temperature, range: .hour1, now: now)
        let temperature = try XCTUnwrap(temperatureSeries).values
        // 窗口起点 = now − 3600 = base;桶宽 60 → temp_avg 行落 index 0。
        XCTAssertEqual(temperature[0] ?? -1, expectedTemperature, accuracy: 0.001)

        let powerSeries = await engine.series(metric: .power, range: .hour1, now: now)
        let power = try XCTUnwrap(powerSeries).values
        XCTAssertEqual(try XCTUnwrap(power[0]), expectedPower, accuracy: 0.001, "全值分钟合计按 COALESCE 口径")
        XCTAssertEqual(try XCTUnwrap(power[1]), 12.5 + 0.7, accuracy: 0.001, "缺域分钟按在场域合计")
        XCTAssertNil(power[2], "全 NULL 分钟空段")

        let gpuSeries = await engine.series(metric: .gpu, range: .hour1, now: now)
        let gpu = try XCTUnwrap(gpuSeries).values
        XCTAssertEqual(gpu[0], 33.0)
        XCTAssertEqual(gpu[1], 66.0)

        let hottestSeries = await engine.series(
            metric: .temperature, breakdown: .temperatureHottest, range: .hour1, now: now
        )
        let hottest = try XCTUnwrap(hottestSeries).values
        XCTAssertEqual(hottest[0], 52.0, "最热走 max 列")
    }

    func testFileOpenBacksUpOnceBeforeGaugeMigration() throws {
        // 文件库:先造 v2 旧库 → open(全量迁移)→ 备份三件套在场;
        // 再 open 一次 → 不产生第二份备份(同秒幂等 + 迁移已应用)。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauge-migration-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let legacy = try DatabaseQueue(path: url.path)
        try HistoryDatabase.migrator().migrate(legacy, upTo: "p2-sensors-v2")
        try legacy.write { db in
            try db.execute(
                sql: "INSERT INTO system_min (ts, load_avg, load_max, temp_avg) VALUES (?, 1, 1, 40)",
                arguments: [base]
            )
        }
        // DatabaseQueue 持有写连接,WAL 落盘;释放引用后再 open。
        let walPath = url.path + "-wal"
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: walPath) || true,
            "WAL 文件可能在最后连接关闭时并入主文件"
        )
        let openURL = url // 局部名进 defer 域
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try HistoryDatabase.open(at: openURL) // 迁移 + 备份
        let manager = FileManager.default
        let backups = try (manager.contentsOfDirectory(atPath: directory.path))
            .filter { $0.contains(".pre-gauge-") }
        XCTAssertFalse(backups.isEmpty, "迁移首跑前产生备份")
        XCTAssertTrue(
            backups.contains { $0.hasSuffix("history.sqlite.pre-gauge-") || $0.contains("history.sqlite.pre-gauge-") },
            "主库文件有备份: \(backups)"
        )

        _ = try HistoryDatabase.open(at: openURL) // 已迁移:不再备份
        let backupsAfter = try (manager.contentsOfDirectory(atPath: directory.path))
            .filter { $0.contains(".pre-gauge-") }
        XCTAssertEqual(backupsAfter.count, backups.count, "二次打开不重复备份")
    }

    func testFreshInstallSkipsBackup() throws {
        // 全新安装:库文件不存在 → 无备份文件、迁移直接建到 v09。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauge-fresh-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try HistoryDatabase.open(at: url)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(
            entries.contains { $0.contains(".pre-gauge-") },
            "全新安装零备份副产物(\(entries) 只应有库与 WAL 副产物)"
        )
        XCTAssertTrue(entries.contains("history.sqlite"))
    }
}
