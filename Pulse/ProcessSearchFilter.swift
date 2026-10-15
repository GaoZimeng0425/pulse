import Foundation

// MARK: - 主窗口搜索过滤

/// 主窗口搜索(纯逻辑):工具栏搜索框按**应用名或进程 id** 过滤排行卡与展开的
/// 进程表——纯视图层过滤,不动采样与分组数据。匹配规则:
/// - 查询去首尾空白、兼容映射(全角数字 → 半角)、小写归一;
/// - 纯数字查询同时命中 **pid 前缀**与名字包含(前缀而非全等,渐进输入下
///   中间态才可见);其余查询只按名字包含,大小写不敏感。
/// 组级口径:组名命中,或组内任一行命中(按 pid 搜要能定位到它所在的组);
/// 组名命中时展开表显示全部行,否则只留命中行。单测见 ProcessSearchFilterTests;
/// 搜索框 UI(⌘F 聚焦 / Esc 清空)属手动验收。
struct ProcessSearchFilter: Equatable, Sendable {
    /// 搜索框绑定值(原始输入,未归一)。
    let query: String

    init(query: String = "") {
        self.query = query
    }

    /// 归一化查询:兼容映射 + 小写(名字匹配大小写不敏感,全角数字兜底)。
    var normalized: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
            .lowercased()
    }

    /// 未在搜索(空白查询):过滤全部旁路,视图与无搜索完全一致。
    var isActive: Bool {
        !normalized.isEmpty
    }

    /// 查询是否纯数字(空查询不算):决定 pid 前缀匹配是否参与。
    private var isNumeric: Bool {
        !normalized.isEmpty && normalized.allSatisfy(\.isNumber)
    }

    /// 名字匹配:大小写不敏感包含。
    func matches(name: String) -> Bool {
        name.precomposedStringWithCompatibilityMapping.lowercased().contains(normalized)
    }

    /// 单个进程行是否命中:名字包含;纯数字查询再按 pid 前缀。
    func matches(row: ProcessRowModel) -> Bool {
        if matches(name: row.name) {
            return true
        }
        return isNumeric && String(row.pid).hasPrefix(normalized)
    }

    /// 组是否命中:组名命中,或任一进程行命中(按 pid 搜要能定位到它所在的组)。
    func matches(group: ProcessGroup, rows: [ProcessRowModel]) -> Bool {
        guard isActive else { return true }
        if matches(name: group.name) {
            return true
        }
        return rows.contains { matches(row: $0) }
    }

    /// 展开组内的可见行:组名命中 → 全部行(按应用名搜 = 看这个应用的全部进程,
    /// 含命名不相干的 helper);否则只留命中行。未在搜索 → 原样返回。
    func filterRows(for group: ProcessGroup, in rows: [ProcessRowModel]) -> [ProcessRowModel] {
        guard isActive, !matches(name: group.name) else { return rows }
        return rows.filter { matches(row: $0) }
    }

    /// 组列表过滤(排行卡口径):组名命中或任一行命中。`rows(for:)` 由调用方注入,
    /// 返回 nil 视为组内行不可知,退化为仅组名匹配(组与下钻同轮落地,实际不走到)。
    static func filteredGroups(
        _ groups: [ProcessGroup],
        filter: ProcessSearchFilter,
        rows: (ProcessGroup) -> [ProcessRowModel]?
    ) -> [ProcessGroup] {
        guard filter.isActive else { return groups }
        return groups.filter { group in
            guard let groupRows = rows(group) else {
                return filter.matches(name: group.name)
            }
            return filter.matches(group: group, rows: groupRows)
        }
    }
}
