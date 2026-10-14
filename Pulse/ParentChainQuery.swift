import Foundation

/// 父链面包屑查询(工单 06,纯函数):从进程自身沿父链追溯到**有归属的祖先**
/// (App 归属的 bundle 祖先,或 launchd),返回显示名序列(自身在前),
/// UI 以 " ← " 连接成 "rustc ← cargo ← node ← Zcode"。
///
/// 追溯口径与归组引擎/出生登记(GLOSSARY)一致:
/// 1. 活链优先——沿快照里的存活 ppid 向上走,每步记名;
/// 2. 链断(中间父已死)或被重挂 launchd(现父=1 但出生记录另有亲父)时,
///    从断点进程自己的出生记录继续上溯——出生记录是父链的出生快照,优先于
///    现场挂靠的 launchd;
/// 3. 终点——bundle 祖先(App 归属)或 launchd(出生即在 launchd 之下,
///    后台服务口径);无记录可查则止于最后已知进程,不臆造祖先。
///
/// 显示名与进程行 / 处置目标同口径:直接走 `PulseFormat.processName`
/// (评审 T5:不再经由本类型的中转包装)。
///
/// 环(异常父链)按已访问 pid 终止;查询的 pid 不在快照(下钻期间进程退出)返回空。
enum ParentChainQuery {
    /// pid 的面包屑显示名序列,自身在前、有归属的祖先殿后。
    static func breadcrumbNames(
        for pid: pid_t,
        in snapshot: ProcessSnapshot,
        lineage: LineageRegistry
    ) -> [String] {
        let processesByPID = snapshot.processesByPID
        guard let process = processesByPID[pid] else { return [] }

        var names = [
            PulseFormat.processName(
                executablePath: process.executablePath,
                argv: process.argv,
                pid: process.pid
            )
        ]
        var visited: Set<pid_t> = [pid]

        // MARK: 活链:沿存活 ppid 向上,直到 bundle 祖先 / 链断 / 遇 launchd。

        var currentPID = pid
        var liveChainBroken = false
        while !liveChainBroken {
            let parentPID = processesByPID[currentPID]?.parentPID ?? 0
            switch parentPID {
            case 0:
                liveChainBroken = true
            case 1:
                // 现父是 launchd:真出生在 launchd 之下则以它为终点;
                // 出生记录另有亲父(中间父死后的重挂)则由出生链接管,不把 launchd 计入。
                if let record = lineage.entries[currentPID],
                   record.parentPID != 1, record.parentPID != 0
                {
                    liveChainBroken = true
                } else {
                    names.append(launchdName(in: processesByPID))
                    return names
                }
            default:
                guard let parent = processesByPID[parentPID], visited.insert(parent.pid).inserted else {
                    liveChainBroken = true // 中间父已死 / 父链成环
                    break
                }
                names.append(
                    PulseFormat.processName(
                        executablePath: parent.executablePath,
                        argv: parent.argv,
                        pid: parent.pid
                    )
                )
                if GroupingEngine.isBundleExecutablePath(parent.executablePath) {
                    return names // 有归属的祖先(bundle):终点
                }
                currentPID = parent.pid
            }
        }

        // MARK: 出生链:从断点进程自己的出生记录继续上溯(GLOSSARY 出生登记)。

        while let record = lineage.entries[currentPID] {
            let parentPID = record.parentPID
            if parentPID == 0 { break }
            if parentPID == 1 {
                names.append(launchdName(in: processesByPID)) // 出生即在 launchd 之下
                break
            }
            guard visited.insert(parentPID).inserted else { break } // 登记链成环
            if let parentRecord = lineage.entries[parentPID] {
                names.append(
                    PulseFormat.processName(
                        executablePath: parentRecord.executablePath,
                        argv: parentRecord.argv,
                        pid: parentPID
                    )
                )
                if GroupingEngine.isBundleExecutablePath(parentRecord.executablePath) {
                    break // 有归属的祖先(bundle,按出生记录):终点
                }
                currentPID = parentPID
            } else if let parent = processesByPID[parentPID] {
                names.append(
                    PulseFormat.processName(
                        executablePath: parent.executablePath,
                        argv: parent.argv,
                        pid: parent.pid
                    )
                )
                if GroupingEngine.isBundleExecutablePath(parent.executablePath) {
                    break
                }
                currentPID = parentPID
            } else {
                break // 父从未被登记也不在快照:止于最后已知进程
            }
        }
        return names
    }

    /// launchd 的名字:快照里有它就用真实路径名,否则用通名。
    private static func launchdName(in processesByPID: [pid_t: RawProcess]) -> String {
        if let launchd = processesByPID[1] {
            return PulseFormat.processName(
                executablePath: launchd.executablePath,
                argv: launchd.argv,
                pid: 1
            )
        }
        return "launchd"
    }
}
