@testable import PulseCore
import XCTest

/// 接缝:告警规则状态机(spec 纯逻辑测试清单:阈值/持续/迟滞/冷却,注入时钟)。
/// 全合成序列 + 注入 Date,零真实等待、零真实负载(工单纪律:真负载属工单 12
/// 验收走查)。覆盖:进入(连续 3 次 + 持续时长)/退出(连续 6 次安全侧)/
/// 迟滞带内两不靠/冷却期抑制重触发/组消失自动解除/新组出生窗/设置变更重置。
final class AlertEngineTests: XCTestCase {
    // MARK: - 合成夹具

    /// 注入时钟的固定起点。
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// 极简策略表:只给被测规则,阈值/持续/冷却逐用例定制(sustain nil = 不限时长,
    /// 只看最少连续次数;cooldown 0 = 冷却不设防,专测 streak 本身)。
    private func policies(
        _ kind: AlertKind,
        enabled: Bool = true,
        threshold: Double,
        sustain: TimeInterval? = nil,
        cooldown: TimeInterval = 0
    ) -> AlertEvaluationSettings {
        var settings = AlertEvaluationSettings()
        // 方向必须走种类预设(磁盘是 below),阈值/持续/冷却逐用例定制。
        settings[kind] = AlertRulePolicy(
            isEnabled: enabled, threshold: threshold, sustain: sustain, cooldown: cooldown,
            direction: kind.preset.direction
        )
        return settings
    }

    private var emptyGroups: [AlertGroupSnapshot] {
        []
    }

    private func group(
        _ id: GroupIdentity, name: String = "组", cpu: Double = 0, memoryGB: Double = 0
    ) -> AlertGroupSnapshot {
        AlertGroupSnapshot(
            id: id, name: name, cpuPercent: cpu, memoryBytes: UInt64(memoryGB * 1_073_741_824)
        )
    }

    // MARK: - 进入:连续 3 次 + 持续时长

    func testSystemLoadFiresOnlyAfterSustainElapsed() {
        // 70% 阈值持续 300s:5s 节奏下 60 轮;streak 第 3 轮就够但时长未满不发,
        // 时长满足的那一轮(距首次越阈 ≥ 300s)才发。
        var engine = AlertEngine()
        let settings = policies(.systemLoad, threshold: 70, sustain: 300)

        for round in 0 ..< 59 {
            let events = engine.record(
                .sampling(systemCPULoad: 71, groups: emptyGroups),
                now: t0.addingTimeInterval(Double(round) * 5),
                settings: settings
            )
            XCTAssertTrue(events.isEmpty, "第 \(round) 轮:时长未满 300s 不发")
        }
        let events = engine.record(
            .sampling(systemCPULoad: 71, groups: emptyGroups),
            now: t0.addingTimeInterval(300),
            settings: settings
        )
        guard case let .fired(occurrence) = events.only else {
            return XCTFail("持续时长满足的当轮应触发,实际 \(events)")
        }
        XCTAssertEqual(occurrence.kind, .systemLoad)
        XCTAssertEqual(occurrence.value, 71, accuracy: 0.001)
    }

    func testEnterNeedsThreeConsecutiveTwoBreachesDoNotFire() {
        // 无持续时长要求的规则(磁盘):连续 2 次越阈不发,第 3 次才发。
        var engine = AlertEngine()
        let settings = policies(.diskAvailable, threshold: Double(20 * 1_073_741_824))
        let low = Int64(19 * 1_073_741_824)

        XCTAssertNil(engine.record(.disk(availableBytes: low), now: t0, settings: settings).only)
        XCTAssertNil(engine.record(.disk(availableBytes: low), now: t0.addingTimeInterval(30), settings: settings).only)
        let events = engine.record(.disk(availableBytes: low), now: t0.addingTimeInterval(60), settings: settings)
        guard case .fired = events.only else { return XCTFail("第 3 次连续越阈应触发,实际 \(events)") }
    }

    func testThresholdEdgeValueDoesNotCountAsBreach() {
        // "超阈"是严格不等:恰在阈值上不算越(磁盘为 < 方向)。
        var engine = AlertEngine()
        let threshold = Double(20 * 1_073_741_824)
        let settings = policies(.diskAvailable, threshold: threshold)

        for round in 0 ..< 3 {
            let events = engine.record(
                .disk(availableBytes: Int64(threshold)),
                now: t0.addingTimeInterval(Double(round) * 30),
                settings: settings
            )
            XCTAssertTrue(events.isEmpty, "恰在阈值上不算越阈")
        }
    }

    // MARK: - 迟滞:带内两不靠

    func testHysteresisBandBreaksEnterStreak() {
        // 磁盘是 below 规则(低于 20GB 告警),迟滞带 = [20, 24) GB:
        // 越(19GB)、带内(22GB)、越、越 → 连续计数被带内打断,重计后仅 2 次,不触发。
        var engine = AlertEngine()
        let threshold = Double(20 * 1_073_741_824)
        let settings = policies(.diskAvailable, threshold: threshold)
        let breach = Int64(19 * 1_073_741_824)
        let inBand = Int64(22 * 1_073_741_824)

        XCTAssertNil(engine.record(.disk(availableBytes: breach), now: t0, settings: settings).only)
        XCTAssertNil(engine.record(.disk(availableBytes: inBand), now: t0.addingTimeInterval(30), settings: settings)
            .only)
        XCTAssertNil(engine.record(.disk(availableBytes: breach), now: t0.addingTimeInterval(60), settings: settings)
            .only)
        let events = engine.record(.disk(availableBytes: breach), now: t0.addingTimeInterval(90), settings: settings)
        XCTAssertTrue(events.isEmpty, "带内打断连续计数:重计后仅 2 次,不触发")
    }

    func testExitNeedsSixSafeRoundsInBandDoesNotCount() throws {
        // 进入后:安全侧(below 规则 = > 阈值×1.2 = 24GB)连续 6 次才解除;
        // 带内值(22GB,在 [20,24) 内)既不推进退出计数,也不触发重发。
        var engine = AlertEngine()
        let threshold = Double(20 * 1_073_741_824)
        let settings = policies(.diskAvailable, threshold: threshold)
        let breach = Int64(10 * 1_073_741_824)
        let inBand = Int64(22 * 1_073_741_824)
        let safe = Int64(25 * 1_073_741_824)
        var now = t0
        var firedAt: Date?

        for _ in 1 ... 3 {
            let events = engine.record(.disk(availableBytes: breach), now: now, settings: settings)
            if case .fired = events.only {
                firedAt = now
            }
            now = now.addingTimeInterval(30)
        }
        let fired = try XCTUnwrap(firedAt, "前置:第 3 次连续应触发")

        // 5 次带内:不得解除。
        for _ in 0 ..< 5 {
            let events = engine.record(.disk(availableBytes: inBand), now: now, settings: settings)
            XCTAssertTrue(events.isEmpty, "带内值不推进退出计数")
            now = now.addingTimeInterval(30)
        }
        // 5 次真安全:尚不足 6 次。
        for _ in 0 ..< 5 {
            let events = engine.record(.disk(availableBytes: safe), now: now, settings: settings)
            XCTAssertTrue(events.isEmpty, "第 \(now.timeIntervalSince(fired))s:安全不足 6 次")
            now = now.addingTimeInterval(30)
        }
        // 第 6 次安全解除。
        guard case let .resolved(kind, _) = engine.record(.disk(availableBytes: safe), now: now, settings: settings)
            .only
        else { return XCTFail("第 6 次安全应解除") }
        XCTAssertEqual(kind, .diskAvailable)
    }

    // MARK: - 冷却期

    func testCooldownSuppressesRefireUntilElapsed() throws {
        // 触发(60s)→ 解除(240s)→ 冷却 600s 内再满足进入条件:不重发;
        // 冷却期满,已满足的 streak 当轮即重发。
        var engine = AlertEngine()
        let settings = policies(.diskAvailable, threshold: Double(20 * 1_073_741_824), cooldown: 600)
        let breach = Int64(10 * 1_073_741_824)
        let safe = Int64(30 * 1_073_741_824)
        var now = t0
        var firedAt: Date?

        func rounds(_ value: Int64, count: Int) {
            for _ in 0 ..< count {
                let events = engine.record(.disk(availableBytes: value), now: now, settings: settings)
                if case .fired = events.only {
                    firedAt = now
                }
                now = now.addingTimeInterval(30)
            }
        }

        rounds(breach, count: 3) // 0–60s:触发
        let fired = try XCTUnwrap(firedAt, "前置:应已触发")
        rounds(safe, count: 6) // 90–240s:解除
        rounds(breach, count: 3) // 270–330s:streak 满,但距触发 270s < 600s 冷却
        XCTAssertTrue(now < fired.addingTimeInterval(600))
        let suppressed = engine.record(.disk(availableBytes: breach), now: now, settings: settings)
        XCTAssertTrue(suppressed.isEmpty, "冷却期内不得重发(实际距上次触发 \(now.timeIntervalSince(fired))s)")

        // 跳过冷却剩余时段(时间轴上直接前进,streak 不因时间间隔断裂,只因非越阈值断裂)。
        now = fired.addingTimeInterval(600)
        let refire = engine.record(.disk(availableBytes: breach), now: now, settings: settings)
        guard case .fired = refire.only else { return XCTFail("冷却期满应重发,实际 \(refire)") }
    }

    // MARK: - 组规则:逐组独立 + 消失解除

    func testGroupCPUStreaksArePerSubject() {
        // 组 A 先高、组 B 后高:A 第 3 轮触发;B 的 streak 独立从 1 数起,不跟 A 混算。
        var engine = AlertEngine()
        let settings = policies(.groupCPU, threshold: 300)
        let a = GroupIdentity.app(bundlePath: "/Applications/A.app")
        let b = GroupIdentity.app(bundlePath: "/Applications/B.app")
        var now = t0

        func sampling(_ groups: [AlertGroupSnapshot]) -> [AlertEvent] {
            let events = engine.record(.sampling(systemCPULoad: 10, groups: groups), now: now, settings: settings)
            now = now.addingTimeInterval(5)
            return events
        }

        XCTAssertNil(sampling([group(a, name: "A", cpu: 310)]).only)
        XCTAssertNil(sampling([group(a, name: "A", cpu: 310)]).only)
        guard case let .fired(a1) = sampling([group(a, name: "A", cpu: 310), group(b, name: "B", cpu: 350)]).only else {
            return XCTFail("A 第 3 次连续应触发")
        }
        XCTAssertEqual(a1.subjectName, "A")
        XCTAssertEqual(a1.kind, .groupCPU)
        // B 这轮才 streak=2,不触发;A 已 firing 不重发。
        XCTAssertTrue(sampling([group(a, name: "A", cpu: 310), group(b, name: "B", cpu: 350)]).isEmpty)
    }

    func testGroupDisappearanceResolvesFiringAlertAndClearsState() {
        var engine = AlertEngine()
        let settings = policies(.groupCPU, threshold: 300)
        let a = GroupIdentity.app(bundlePath: "/Applications/A.app")
        var now = t0

        func sampling(_ groups: [AlertGroupSnapshot]) -> [AlertEvent] {
            let events = engine.record(.sampling(systemCPULoad: 10, groups: groups), now: now, settings: settings)
            now = now.addingTimeInterval(5)
            return events
        }

        var fired = false
        for _ in 0 ..< 3 {
            if case .fired = sampling([group(a, name: "A", cpu: 400)]).only {
                fired = true
            }
        }
        XCTAssertTrue(fired, "前置:A 应已触发")
        // 组消失:立即解除(firing → resolved),状态清空。
        guard case let .resolved(kind, subject) = sampling([]).only else {
            return XCTFail("组消失应解除告警")
        }
        XCTAssertEqual(kind, .groupCPU)
        XCTAssertEqual(subject, "bundle:/Applications/A.app")
        // 重生的同 id 组从头计数(状态已清),不立刻重发。
        XCTAssertNil(sampling([group(a, name: "A", cpu: 400)]).only)
    }

    // MARK: - 新组内存

    func testNewGroupMemoryFiresWithinBirthWindowOnly() {
        // 出生窗:新组(上轮不在场)前 3 个观察连续超 2GB → 第 3 轮触发;
        // 出生时低于阈值、出生窗过后才涨上去的,不算"新组内存告警"。
        var engine = AlertEngine()
        let settings = policies(.newGroupMemory, threshold: Double(2 * 1_073_741_824))
        let big = GroupIdentity.app(bundlePath: "/Applications/Big.app")
        let late = GroupIdentity.app(bundlePath: "/Applications/Late.app")
        var now = t0

        func sampling(_ groups: [AlertGroupSnapshot]) -> [AlertEvent] {
            let events = engine.record(.sampling(systemCPULoad: 10, groups: groups), now: now, settings: settings)
            now = now.addingTimeInterval(5)
            return events
        }

        // 首轮全量在场:一概不算新组(首读立基线,同吞吐差分首读置零惯例)。
        XCTAssertTrue(sampling([group(big, name: "Big", memoryGB: 5)]).isEmpty, "首轮不判新组")

        // Big 消失后重生,出生即 >2GB 且稳住 3 轮 → 第 3 轮触发。
        _ = sampling([])
        XCTAssertTrue(sampling([group(big, name: "Big", memoryGB: 5)]).isEmpty)
        XCTAssertTrue(sampling([group(big, name: "Big", memoryGB: 5)]).isEmpty)
        guard case let .fired(occurrence) = sampling([group(big, name: "Big", memoryGB: 5)]).only else {
            return XCTFail("新组连续 3 轮 >2GB 应触发")
        }
        XCTAssertEqual(occurrence.kind, .newGroupMemory)
        XCTAssertEqual(occurrence.subjectName, "Big")

        // 出生时 1GB、出生窗外才涨过阈:不触发。
        _ = sampling([]) // Big 消失(顺带解除其 firing——非本用例断言点)
        _ = sampling([group(late, name: "Late", memoryGB: 1)])
        _ = sampling([group(late, name: "Late", memoryGB: 1)])
        _ = sampling([group(late, name: "Late", memoryGB: 1)])
        XCTAssertTrue(sampling([group(late, name: "Late", memoryGB: 5)]).isEmpty, "出生窗外的内存增长不算新组告警")
        XCTAssertTrue(sampling([group(late, name: "Late", memoryGB: 5)]).isEmpty)
    }

    // MARK: - 设置变更 / 开关

    func testConfigChangeResolvesFiringAndResetsStreaks() {
        var engine = AlertEngine()
        let old = policies(.systemLoad, threshold: 70, sustain: 0)
        let new = policies(.systemLoad, threshold: 90, sustain: 0)
        var now = t0

        func sampling(_ load: Double, settings: AlertEvaluationSettings) -> [AlertEvent] {
            let events = engine.record(
                .sampling(systemCPULoad: load, groups: emptyGroups),
                now: now,
                settings: settings
            )
            now = now.addingTimeInterval(5)
            return events
        }

        var fired = false
        for _ in 0 ..< 3 {
            if case .fired = sampling(80, settings: old).only {
                fired = true
            }
        }
        XCTAssertTrue(fired, "前置:应已触发")

        // 阈值改动即时生效:firing 立即解除、streak 重置。80 对新阈值 90 只在
        // 迟滞带内,换 95 继续越阈验证重置后的计数从头数起。
        guard case .resolved = sampling(80, settings: new).only else {
            return XCTFail("设置变更应解除既有告警")
        }
        XCTAssertNil(sampling(95, settings: new).only, "重置后 streak=1,不发")
        XCTAssertNil(sampling(95, settings: new).only, "重置后 streak=2,不发")
        guard case .fired = sampling(95, settings: new).only else {
            return XCTFail("新阈值下 streak 满 3 应触发")
        }
    }

    func testDisabledRuleNeverEvaluates() {
        var engine = AlertEngine()
        let settings = policies(.systemLoad, enabled: false, threshold: 70, sustain: 0)
        var now = t0
        for _ in 0 ..< 5 {
            let events = engine.record(
                .sampling(systemCPULoad: 99, groups: emptyGroups), now: now, settings: settings
            )
            XCTAssertTrue(events.isEmpty)
            now = now.addingTimeInterval(5)
        }
    }

    // MARK: - 路由(点通知直达)

    func testRouteMappingMatchesSpec() {
        // 系统负载→总览、组 CPU→CPU 页、磁盘→磁盘页(工单验收三项);
        // 新组内存落内存页(同构延伸,工单未点名)。
        XCTAssertEqual(AlertKind.systemLoad.route.tab, .overview)
        XCTAssertEqual(AlertKind.groupCPU.route.tab, .cpu)
        XCTAssertEqual(AlertKind.diskAvailable.route.tab, .disk)
        XCTAssertEqual(AlertKind.newGroupMemory.route.tab, .memory)
    }

    // MARK: - 预设默认值(与 spec 逐项钉死)

    func testPresetDefaultsMatchSpec() {
        XCTAssertEqual(AlertKind.systemLoad.preset.threshold, 70)
        XCTAssertEqual(AlertKind.systemLoad.preset.sustain, 300)
        XCTAssertEqual(AlertKind.groupCPU.preset.threshold, 300)
        XCTAssertEqual(AlertKind.groupCPU.preset.sustain, 600)
        XCTAssertEqual(AlertKind.newGroupMemory.preset.threshold, Double(2 * 1_073_741_824))
        XCTAssertNil(AlertKind.newGroupMemory.preset.sustain)
        XCTAssertEqual(AlertKind.diskAvailable.preset.threshold, Double(20 * 1_073_741_824))
        XCTAssertNil(AlertKind.diskAvailable.preset.sustain)
        // 迟滞系数与进出次数是引擎常量。
        XCTAssertEqual(AlertEngine.minimumConsecutiveEnter, 3)
        XCTAssertEqual(AlertEngine.exitConsecutive, 6)
        XCTAssertEqual(AlertEngine.hysteresisFraction, 0.2, accuracy: 0.0001)
    }
}

// MARK: - 小助手

private extension Array {
    /// 单事件断言用:恰一个元素返回它,否则 nil(让 XCTAssertNil/XCTUnwrap 直读)。
    var only: Element? {
        count == 1 ? first : nil
    }
}
