@testable import PulseCore
import XCTest

/// NemoNotch toast 文案拼装单测(公开契约 v1):四类进 toast(dev server 不进)、
/// 标题点名承载组、正文列进程与数值、key 消毒 `::` 并钳长、title/body 钳到
/// 契约上限(超限 NemoNotch 侧直接 400,拼装侧必须兜住)。
final class NemoNotchToastContentTests: XCTestCase {
    private func fired(
        _ kind: AlertKind,
        subjectKey: String = "system",
        subjectName: String? = nil,
        value: Double
    ) -> AlertOccurrence {
        AlertOccurrence(kind: kind, subjectKey: subjectKey, subjectName: subjectName, value: value, firedAt: Date())
    }

    private func entry(_ name: String, cpu: Double?, memory: UInt64 = 0) -> AlertOffenderEntry {
        AlertOffenderEntry(name: name, cpuPercent: cpu, memoryBytes: memory)
    }

    /// 系统负载:标题点名第一名组,正文列 CPU 前几名(带 %)。
    func testSystemLoadTitleNamesGroupBodyNamesProcesses() throws {
        let made = NemoNotchToastContent.make(
            for: fired(.systemLoad, value: 87.4),
            offender: AlertOffenderSummary(groupName: "octok @ wt", entries: [
                entry("electron", cpu: 320.4),
                entry("node", cpu: 88),
                entry("rustc", cpu: nil),
            ]),
            jumpBundleId: "com.gaozimeng.pulse"
        )
        let toast = try XCTUnwrap(made)
        XCTAssertEqual(toast.title, "系统负载过高:octok @ wt")
        // 无差分的进程只列名不伪造 0%。
        XCTAssertEqual(toast.body, "最耗 CPU:electron 320%、node 88%、rustc")
        XCTAssertEqual(toast.icon, "sf:cpu")
        XCTAssertEqual(toast.jumpBundleId, "com.gaozimeng.pulse")
        XCTAssertEqual(toast.key, "alert|systemLoad|system")
    }

    /// 系统负载但归因为空(组表空转):标题不带组名,正文走兜底句。
    func testSystemLoadWithoutOffenderFallsBack() throws {
        let made = NemoNotchToastContent.make(
            for: fired(.systemLoad, value: 90),
            offender: .none,
            jumpBundleId: nil
        )
        let toast = try XCTUnwrap(made)
        XCTAssertEqual(toast.title, "系统负载过高")
        XCTAssertEqual(toast.body, "最耗 CPU:进程已不在场,打开 Pulse 查看排行。")
    }

    /// 组 CPU:标题 = 组名 + 读数;key 带主体 stableKey。
    func testGroupCPUCarriesSubjectNameAndKey() throws {
        let made = NemoNotchToastContent.make(
            for: fired(.groupCPU, subjectKey: "project:/Users/x/pulse@wt", subjectName: "pulse @ wt", value: 310.6),
            offender: AlertOffenderSummary(groupName: "pulse @ wt", entries: [entry("swift-frontend", cpu: 280)]),
            jumpBundleId: nil
        )
        let toast = try XCTUnwrap(made)
        XCTAssertEqual(toast.title, "「pulse @ wt」CPU 311%")
        XCTAssertEqual(toast.body, "最耗 CPU:swift-frontend 280%")
        XCTAssertEqual(toast.key, "alert|groupCPU|project:/Users/x/pulse@wt")
    }

    /// 新组内存:正文按内存口径(十进制单位)。
    func testNewGroupMemoryUsesMemoryFormatting() throws {
        let made = NemoNotchToastContent.make(
            for: fired(.newGroupMemory, subjectKey: "bundle:/x.app", subjectName: "Zap", value: 2.4 * 1_000_000_000),
            offender: AlertOffenderSummary(groupName: "Zap", entries: [
                entry("helper", cpu: 12, memory: 1_500_000_000),
            ]),
            jumpBundleId: nil
        )
        let toast = try XCTUnwrap(made)
        XCTAssertEqual(toast.title, "新组「Zap」内存 2.4 GB")
        XCTAssertEqual(toast.body, "占内存最多:helper 1.5 GB")
        XCTAssertEqual(toast.icon, "sf:memorychip")
    }

    /// 磁盘:无归因,正文沿用系统通知口径(两位小数容量)。
    func testDiskMirrorsSystemNotificationCopy() throws {
        let made = NemoNotchToastContent.make(
            for: fired(.diskAvailable, subjectKey: "disk", value: 12 * 1_000_000_000),
            offender: .none,
            jumpBundleId: nil
        )
        let toast = try XCTUnwrap(made)
        XCTAssertEqual(toast.title, "磁盘可用不足")
        XCTAssertEqual(toast.body, "可用 12.00 GB,剩余空间紧张。")
        XCTAssertEqual(toast.icon, "sf:internaldrive")
        XCTAssertEqual(toast.key, "alert|diskAvailable|disk")
    }

    /// dev server 闲置:不进 toast。
    func testDevServerIdleYieldsNil() {
        let made = NemoNotchToastContent.make(
            for: fired(.devServerIdle, subjectKey: "devserver|42", subjectName: "vite", value: 90000),
            offender: .none,
            jumpBundleId: nil
        )
        XCTAssertNil(made)
    }

    /// key 消毒:契约禁 `::`(stableKey 里的路径/worktree 名不该炸,但硬防线必须有),且钳 128。
    func testKeySanitizesDoubleColonAndClamps() {
        let dirty = fired(.groupCPU, subjectKey: String(repeating: "a::", count: 100), value: 400)
        let key = NemoNotchToastContent.key(for: dirty)
        XCTAssertFalse(key.contains("::"))
        XCTAssertLessThanOrEqual(key.count, NemoNotchToastContent.keyLimit)
        // 截断保前缀:种类标识必须在。
        XCTAssertTrue(key.hasPrefix("alert|groupCPU|"))
    }

    /// 标题/正文钳长:超长组名不越过契约上限(超限即 400)。
    func testTitleAndBodyClampToContractLimits() throws {
        let longName = String(repeating: "超", count: 200)
        let made = NemoNotchToastContent.make(
            for: fired(.groupCPU, subjectKey: "x", subjectName: longName, value: 400),
            offender: AlertOffenderSummary(groupName: longName, entries: [
                entry(longName, cpu: 400, memory: 0),
            ]),
            jumpBundleId: nil
        )
        let toast = try XCTUnwrap(made)
        XCTAssertLessThanOrEqual(toast.title.count, NemoNotchToastContent.titleLimit)
        XCTAssertLessThanOrEqual(toast.body?.count ?? 0, NemoNotchToastContent.bodyLimit)
    }

    /// 请求体封套:契约键名齐全、schema/app 恒定、nil 可选缺省(encodeIfPresent)。
    func testEnvelopeEncodesContractKeysAndOmitsNilOptionals() throws {
        let envelope = NemoNotchToastPayload(
            key: "k", title: "t", body: nil, icon: "sf:cpu", jumpBundleId: nil
        ).envelope
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(envelope)
        ) as? [String: Any])
        XCTAssertEqual(json["schema"] as? Int, 1)
        XCTAssertEqual(json["app"] as? String, "Pulse")
        XCTAssertEqual(json["key"] as? String, "k")
        XCTAssertEqual(json["title"] as? String, "t")
        XCTAssertEqual(json["icon"] as? String, "sf:cpu")
        XCTAssertNil(json["body"]) // nil 可选必须缺省,不能是 null/空串
        XCTAssertNil(json["jumpBundleId"])
    }
}
