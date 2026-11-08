import Foundation

// MARK: - 删除计划(p4-cleaner/04;ADR-0008 的多重闸门在纯值层的那几道)

//
// 勾选态 → 计划(= 确认清单)→ 执行报告。三个纯值,零 IO:
//   - JunkSelection:默认全不勾(spec Story 4);先检查项也只能由用户亲手勾。
//   - CleanPlan:选中 ∩ 当前清单 ∩ 非排除——删除前**再判一次排除**(票面"两处生效"),
//     用的是和扫描侧同一份 CleanExclusions 判定。
//   - CleanRunner:把计划交给 CleanTrashExecutor(唯一删除出口),按路径逐项核对回执,
//     执行器没报到的项按失败记——不默认成功(防御性数据纪律:不伪造结果)。交之前先过
//     删前复核(p5-cleaner/03,`PreDeleteCheck`):扫描后动过 / 已不在 / 无快照的项跳过。

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

    // MARK: 整组勾选(2026-10-30 用户拍板 B:组头 checkbox 一键勾/清组内「可安全清理」项,

    // 先检查项永不经组勾选进入——调用方只传 safe 档候选,这条约定钉死在这里)

    /// 一组候选(或任意子集)的勾选三态:组头 checkbox 的显示与点击语义。
    public enum GroupState: Sendable, Equatable {
        case none
        case mixed
        case all
    }

    /// 子集勾选态:0 勾 = none,部分 = mixed,全勾 = all;空集 = none。
    public func state(of candidates: [JunkCandidate]) -> GroupState {
        guard !candidates.isEmpty else { return .none }
        let selected = candidates.count { paths.contains($0.path) }
        if selected == 0 {
            return .none
        }
        return selected == candidates.count ? .all : .mixed
    }

    /// 批量设置,**只动这里传入的候选**(整组勾选的落点;其他组 / 其他档位不受影响)。
    public mutating func set(_ selected: Bool, for candidates: [JunkCandidate]) {
        for candidate in candidates {
            set(candidate, selected: selected)
        }
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

    /// 没有删前复核快照的项(旧版缓存带来的结果):执行时必被跳过——确认单据此提前说明,
    /// 不让用户点了「移入废纸篓」才发现一项没动。
    public var itemsWithoutSnapshot: [JunkCandidate] {
        items.filter { $0.modifiedAtScan == nil }
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
    /// 未经废纸篓的永久删除(p4-uninstaller/03)。路由两态,历史文案映射:
    /// .direct = 「永久删除」(非 brew 彻底删除);.brew = 「已卸载(brew,永久)」
    /// (brew uninstall / --zap 带走——app 本体恒此路由,zap 覆盖的残留同)。
    case permanentlyDeleted(route: PermanentDeleteRoute)
    /// 未能移入;`reason` 为人话(进确认结果的失败清单与清理历史)。
    case failed(reason: String)
}

/// 永久删除的路由(历史与横幅的文案分叉;ADR-0010:废纸篓是默认技术路径而非原则)。
public enum PermanentDeleteRoute: String, Sendable, Equatable {
    /// 非 brew 应用的「彻底删除」直删。
    case direct
    /// Homebrew 卸载(uninstall / --zap)带走——文件由 brew 删除,不经我们手。
    case brew
}

/// 报告里的一行(= 计划里的一项 + 去向)。
public struct CleanRunItem: Sendable, Equatable {
    public let path: String
    public let title: String
    public let bytes: Int64
    public let tier: CleanSafetyTier
    public let ruleID: String
    public let outcome: CleanItemOutcome

    public init(
        path: String,
        title: String,
        bytes: Int64,
        tier: CleanSafetyTier,
        ruleID: String,
        outcome: CleanItemOutcome
    ) {
        self.path = path
        self.title = title
        self.bytes = bytes
        self.tier = tier
        self.ruleID = ruleID
        self.outcome = outcome
    }

    public var isRecycled: Bool {
        if case .recycled = outcome {
            return true
        }
        return false
    }

    /// 已离开本机(废纸篓或永久删除)——释放量与成功计数的口径(p4-uninstaller/03)。
    public var isReleased: Bool {
        switch outcome {
        case .recycled, .permanentlyDeleted: true
        case .failed: false
        }
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

    /// 永久删除项(p4-uninstaller/03;一期恒空)。
    public var permanentItems: [CleanRunItem] {
        items.filter {
            if case .permanentlyDeleted = $0.outcome {
                return true
            }
            return false
        }
    }

    public var failed: [CleanRunItem] {
        items.filter { !$0.isReleased }
    }

    /// 已释放字节(废纸篓 + 永久删除;失败项不计)。一期没有永久删除项,
    /// 语义扩展对既有行为零影响(2026-11-04 Q14 完成横幅与历史共用此口径)。
    public var freedBytes: Int64 {
        items.filter(\.isReleased).reduce(0) { $0 + $1.bytes }
    }

    public var recycledPaths: Set<String> {
        Set(recycled.map(\.path))
    }
}

/// 执行计划:先删前复核,放行项一次交给执行器,按路径逐项对回执。
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
        // 删前复核(spec §15):逐项比对扫描快照;跳过项不进执行器批次,战报如实记原因。
        let check = await PreDeleteCheck.partition(
            plan.items,
            path: \.path,
            snapshot: \.modifiedAtScan,
            origin: .scan,
            currentState: { await executor.currentState(ofPath: $0) }
        )
        let outcome = check.cleared.isEmpty
            ? TrashRecycleOutcome()
            : await executor.recycleToTrash(check.cleared.map(\.path))
        let items = plan.items.map { candidate -> CleanRunItem in
            let result: CleanItemOutcome = if let skipped = check.skipped[candidate.path] {
                .failed(reason: skipped)
            } else if let destination = outcome.recycled[candidate.path] {
                .recycled(destination: destination)
            } else if let reason = outcome.failures[candidate.path] {
                .failed(reason: reason)
            } else {
                // 执行器既没说成功也没说失败:按失败记,不默认成功。
                .failed(reason: "执行器未报告结果")
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
