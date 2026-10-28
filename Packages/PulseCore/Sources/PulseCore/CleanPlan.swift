import Foundation

// MARK: - 删除计划(p4-cleaner/04;ADR-0008 的多重闸门在纯值层的那几道)

//
// 勾选态 → 计划(= 确认清单)→ 执行报告。三个纯值,零 IO:
//   - JunkSelection:默认全不勾(spec Story 4);先检查项也只能由用户亲手勾。
//   - CleanPlan:选中 ∩ 当前清单 ∩ 非排除——删除前**再判一次排除**(票面"两处生效"),
//     用的是和扫描侧同一份 CleanExclusions 判定。
//   - CleanRunner:把计划交给 CleanTrashExecutor(唯一删除出口),按路径逐项核对回执,
//     执行器没报到的项按失败记——不默认成功(防御性数据纪律:不伪造结果)。

/// 清单勾选态。只存路径;清单刷新后用 `retain(in:)` 收敛,消失的项自动脱勾。
public struct JunkSelection: Sendable, Equatable {
    public private(set) var paths: Set<String> = []

    public init() {}

    public var isEmpty: Bool {
        paths.isEmpty
    }

    public var count: Int {
        paths.count
    }

    public func contains(_ candidate: JunkCandidate) -> Bool {
        paths.contains(candidate.path)
    }

    public mutating func toggle(_ candidate: JunkCandidate) {
        if paths.contains(candidate.path) {
            paths.remove(candidate.path)
        } else {
            paths.insert(candidate.path)
        }
    }

    public mutating func set(_ candidate: JunkCandidate, selected: Bool) {
        if selected {
            paths.insert(candidate.path)
        } else {
            paths.remove(candidate.path)
        }
    }

    public mutating func clear() {
        paths.removeAll()
    }

    /// 只保留仍在清单里的路径(被删掉 / 被排除 / 重扫后消失的项不残留勾)。
    public mutating func retain(in candidates: [JunkCandidate]) {
        let live = Set(candidates.map(\.path))
        paths = paths.intersection(live)
    }
}

/// 确认清单(= 这次要移入废纸篓的东西)。
public struct CleanPlan: Sendable, Equatable {
    public let items: [JunkCandidate]

    public init(items: [JunkCandidate]) {
        self.items = items
    }

    public var isEmpty: Bool {
        items.isEmpty
    }

    /// 实际占用口径合计(GLOSSARY)。
    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    /// 全部项都是 PRIVATESIZE 口径;false = 混了回退口径,确认清单要注记。
    public var allReclaimableAccounting: Bool {
        items.allSatisfy(\.allReclaimableAccounting)
    }

    public var hasPartialItems: Bool {
        items.contains(where: \.isPartial)
    }

    /// 由勾选态与当前清单产出计划。排除前缀在此**二次判定**:扫完后新加的排除、设置页里
    /// 刚加的排除,都在删除前再挡一次。顺序沿用清单顺序(确认清单与列表同序,好对眼)。
    public static func make(
        selection: JunkSelection,
        candidates: [JunkCandidate],
        excludedPathPrefixes: [String]
    ) -> CleanPlan {
        CleanPlan(items: candidates.filter {
            selection.contains($0) && !CleanExclusions.isExcluded($0.path, by: excludedPathPrefixes)
        })
    }
}

// MARK: - 执行与报告

/// 一项的执行去向。
public enum CleanItemOutcome: Sendable, Equatable {
    /// 已移入废纸篓,`destination` = 废纸篓内路径(探针 12:recycle 回赠)。
    case recycled(destination: String)
    /// 未能移入;`reason` 为人话(进确认结果的失败清单与清理历史)。
    case failed(reason: String)
}

/// 报告里的一行(= 计划里的一项 + 去向)。
public struct CleanRunItem: Sendable, Equatable {
    public let path: String
    public let title: String
    public let bytes: Int64
    public let tier: CleanSafetyTier
    public let ruleID: String
    public let outcome: CleanItemOutcome

    public init(path: String, title: String, bytes: Int64, tier: CleanSafetyTier, ruleID: String, outcome: CleanItemOutcome) {
        self.path = path
        self.title = title
        self.bytes = bytes
        self.tier = tier
        self.ruleID = ruleID
        self.outcome = outcome
    }

    public var isRecycled: Bool {
        if case .recycled = outcome { return true }
        return false
    }
}

/// 一次清理的战报(= 清理历史的一个 run)。
public struct CleanRunReport: Sendable, Equatable {
    public let startedAt: Date
    public let finishedAt: Date
    public let items: [CleanRunItem]

    public init(startedAt: Date, finishedAt: Date, items: [CleanRunItem]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.items = items
    }

    public var recycled: [CleanRunItem] {
        items.filter(\.isRecycled)
    }

    public var failed: [CleanRunItem] {
        items.filter { !$0.isRecycled }
    }

    /// 已释放字节(只算真进了废纸篓的项;失败项不计)。
    public var freedBytes: Int64 {
        recycled.reduce(0) { $0 + $1.bytes }
    }

    public var recycledPaths: Set<String> {
        Set(recycled.map(\.path))
    }
}

/// 执行计划:一次交给执行器,按路径逐项对回执。
public enum CleanRunner {
    public static func run(
        _ plan: CleanPlan,
        using executor: some CleanTrashExecutor,
        now: @Sendable () -> Date = { Date() }
    ) async -> CleanRunReport {
        let startedAt = now()
        guard !plan.isEmpty else {
            return CleanRunReport(startedAt: startedAt, finishedAt: startedAt, items: [])
        }
        let outcome = await executor.recycleToTrash(plan.items.map(\.path))
        let items = plan.items.map { candidate -> CleanRunItem in
            let result: CleanItemOutcome
            if let destination = outcome.recycled[candidate.path] {
                result = .recycled(destination: destination)
            } else if let reason = outcome.failures[candidate.path] {
                result = .failed(reason: reason)
            } else {
                // 执行器既没说成功也没说失败:按失败记,不默认成功。
                result = .failed(reason: "执行器未报告结果")
            }
            return CleanRunItem(
                path: candidate.path,
                title: candidate.title,
                bytes: candidate.bytes,
                tier: candidate.tier,
                ruleID: candidate.ruleID,
                outcome: result
            )
        }
        return CleanRunReport(startedAt: startedAt, finishedAt: now(), items: items)
    }
}
