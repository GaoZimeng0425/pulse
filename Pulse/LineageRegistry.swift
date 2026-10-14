import Foundation

/// 出生登记(GLOSSARY,内存版):新进程出生时记录的父链快照,活链断裂后回查归属。
/// 值类型,两个登记来源汇合(评审 S1):
/// - **独立出生扫描**(BirthScanner,spec"每 2s 扫描新出现的 pid"):~2s 节奏
///   对新 pid 即时登记——短命父进程在两次采样之间退场前也能留下出生快照;
/// - **采样轮兜底**(GroupingPipeline 每轮 `registeringBirths(in:)`):把快照里
///   首次出现的进程补登记,覆盖扫描间隙的漏网。
/// 两者的表经 `merging(_:)` 只补缺地汇合;归组引擎自身不持有、不更新任何状态。
/// 每个进程只在首次出现时登记(pid、父 pid、路径、cwd、argv);父链经由各进程
/// 自己的记录串联而成。重启即失(P0 决定,SQLite 随 P1);pid 复用不做区分(已知限制)。
struct LineageRegistry: Equatable, Sendable {
    /// 单条出生记录:进程出生时刻的可归属字段。
    struct Entry: Equatable, Sendable {
        let parentPID: pid_t
        let executablePath: String?
        let cwd: String?
        let argv: [String]
    }

    /// pid → 出生记录。
    private(set) var entries: [pid_t: Entry] = [:]

    /// 登记快照中首次出现的进程(出生登记)。纯函数:返回新表,不改动自身。
    func registeringBirths(in snapshot: ProcessSnapshot) -> LineageRegistry {
        var updated = self
        for process in snapshot.processes where updated.entries[process.pid] == nil {
            updated.entries[process.pid] = Entry(
                parentPID: process.parentPID,
                executablePath: process.executablePath,
                cwd: process.cwd,
                argv: process.argv
            )
        }
        return updated
    }

    /// 登记单个新出生(出生扫描器逐 pid 用):已有记录或查询失败(entry 为 nil,
    /// pid 在枚举与查询之间退出)时幂等无操作——首记为准,不覆盖。
    mutating func register(pid: pid_t, entry: Entry?) {
        guard let entry, entries[pid] == nil else { return }
        entries[pid] = entry
    }

    /// 融合两张登记表(出生扫描 ↔ 采样轮兜底):两侧都有的 pid 保留自身(左侧)
    /// 的首次记录,只从右侧补缺。纯函数:返回新表,不改动自身。
    func merging(_ other: LineageRegistry) -> LineageRegistry {
        guard !other.entries.isEmpty else { return self }
        var merged = self
        for (pid, entry) in other.entries where merged.entries[pid] == nil {
            merged.entries[pid] = entry
        }
        return merged
    }
}
