import Foundation

/// 出生登记(GLOSSARY,内存版):新进程出生时记录的父链快照,活链断裂后回查归属。
/// 值类型:采样方(工单 04)每轮以约 2s 节奏先 `registeringBirths(in:)` 得到新登记表,
/// 再连同快照一起交给归组引擎——引擎自身不持有、不更新任何状态。
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
}
