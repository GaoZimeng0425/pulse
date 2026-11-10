import Foundation

// MARK: - 清理总览聚合(p6-cleaner/03,丙案 v2):候选 × 活动条目 → 品类聚合行

//
// 总览页的数字全部出自这里(UI 只描边),形状仿 ModuleRanking:输入纯值、输出纯值、
// 零 IO。三段构成(safe / check / inuse)是**互斥切分**——在用是与档位正交的客观状态
// (safe 项也会被在用保护),所以 inuse 段吃掉它在用期间的全部字节,safe/check 段只计
// 各自档位里**非在用**的部分:三段相加恒等于合计,构成条不重不漏。
// 「safe 合计」因此天然 = 「一键清理安全项」可自动勾选的量(见 safeAutoSelection)。
// 在用判定永不缓存(spec 口径):调用方每次渲染 / 每次点击现查活动源,把 entries 传进来。

/// 一个品类的聚合行(总览模块大卡的数据面)。品类没有候选就不建行——空组卡不出。
public struct JunkOverviewGroupRow: Sendable, Equatable, Identifiable {
    public var id: String {
        group.rawValue
    }

    public let group: JunkGroup
    public let itemCount: Int
    /// 品类合计(= safeBytes + checkBytes + inUseBytes,互斥三段之和)。
    public let totalBytes: Int64
    /// 「可安全清理」档且**非在用**的合计(= 一键可自动勾选的量)。
    public let safeBytes: Int64
    /// 「先检查」档且非在用的合计。
    public let checkBytes: Int64
    /// 在用保护项的合计(任意档位;在用是客观状态,正交于档位)。
    public let inUseBytes: Int64
    /// 该品类最大一项(按字节;行必有候选才存在,所以非空)。
    public let largestTitle: String
    public let largestBytes: Int64

    public init(
        group: JunkGroup,
        itemCount: Int,
        totalBytes: Int64,
        safeBytes: Int64,
        checkBytes: Int64,
        inUseBytes: Int64,
        largestTitle: String,
        largestBytes: Int64
    ) {
        self.group = group
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.safeBytes = safeBytes
        self.checkBytes = checkBytes
        self.inUseBytes = inUseBytes
        self.largestTitle = largestTitle
        self.largestBytes = largestBytes
    }
}

/// 总览聚合结果:品类行(Hero 与模块大卡的共同数据源)。
public struct JunkOverview: Sendable, Equatable {
    /// 品类行,按 `JunkGroup.allCases` 顺序;空组不出行。
    public let rows: [JunkOverviewGroupRow]

    public init(rows: [JunkOverviewGroupRow]) {
        self.rows = rows
    }

    public var totalBytes: Int64 {
        rows.reduce(0) { $0 + $1.totalBytes }
    }

    /// 一键可自动勾选的量(= 各行 safeBytes 之和)。
    public var safeBytes: Int64 {
        rows.reduce(0) { $0 + $1.safeBytes }
    }

    public var checkBytes: Int64 {
        rows.reduce(0) { $0 + $1.checkBytes }
    }

    public var inUseBytes: Int64 {
        rows.reduce(0) { $0 + $1.inUseBytes }
    }

    public var itemCount: Int {
        rows.reduce(0) { $0 + $1.itemCount }
    }

    public var isEmpty: Bool {
        rows.isEmpty
    }

    public func row(for group: JunkGroup) -> JunkOverviewGroupRow? {
        rows.first { $0.group == group }
    }
}

public enum JunkOverviewAggregator {
    /// 候选 → 总览聚合。活动条目由调用方**当次现查**后传入(判定不缓存的纪律在调用侧);
    /// 在用判定与清单行 / 删除计划同口径(`CleanInUse`,单出处)。
    public static func overview(
        candidates: [JunkCandidate],
        activityEntries: [CleanActivityEntry]
    ) -> JunkOverview {
        var rowList: [JunkOverviewGroupRow] = []
        for group in JunkGroup.allCases {
            let items = candidates.filter { $0.group == group }
            guard !items.isEmpty else { continue } // 空组不出行
            var safeBytes: Int64 = 0
            var checkBytes: Int64 = 0
            var inUseBytes: Int64 = 0
            var largest = items[0]
            for item in items {
                if isInUse(item, entries: activityEntries) {
                    inUseBytes += item.bytes
                } else if item.tier == .safe {
                    safeBytes += item.bytes
                } else {
                    checkBytes += item.bytes
                }
                if item.bytes > largest.bytes {
                    largest = item
                }
            }
            rowList.append(
                JunkOverviewGroupRow(
                    group: group,
                    itemCount: items.count,
                    totalBytes: safeBytes + checkBytes + inUseBytes,
                    safeBytes: safeBytes,
                    checkBytes: checkBytes,
                    inUseBytes: inUseBytes,
                    largestTitle: largest.title,
                    largestBytes: largest.bytes
                )
            )
        }
        return JunkOverview(rows: rowList)
    }

    /// 全部清单按品类过滤(`nil` = 全量)。下钻(p6-cleaner/03)与全量同源同序,
    /// 只做一层过滤,不重排——组内排序仍归清单视图的既有 sortOrder。
    public static func filtered(
        _ candidates: [JunkCandidate],
        by group: JunkGroup?
    ) -> [JunkCandidate] {
        guard let group else { return candidates }
        return candidates.filter { $0.group == group }
    }

    /// 一键清理安全项(spec 定案 6):全部「可安全清理」且**非在用**的候选——
    /// 「先检查」档与在用保护项永不在内(与组头「全选安全项」、MCP 求交同一口径,
    /// 删除侧另有 plan 二次判定兜底)。返回保持清单顺序。
    public static func safeAutoSelection(
        candidates: [JunkCandidate],
        activityEntries: [CleanActivityEntry]
    ) -> [JunkCandidate] {
        candidates.filter { candidate in
            candidate.tier == .safe && !isInUse(candidate, entries: activityEntries)
        }
    }

    // MARK: - 内部

    private static func isInUse(
        _ candidate: JunkCandidate,
        entries: [CleanActivityEntry]
    ) -> Bool {
        CleanInUse.reasons(
            protectingPath: CleanInUse.protectionPath(for: candidate),
            entries: entries
        ) != nil
    }
}
