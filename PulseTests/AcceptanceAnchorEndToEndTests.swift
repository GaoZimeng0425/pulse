import XCTest
import Darwin
@testable import Pulse

/// P0 验收锚点端到端(工单 09):spec 锚点是"某项目门禁(rustc×N ← cargo ← node ←
/// 拉起会话)"——本机不可召唤那条确切链,用**同构的真实负载**做可复现代理:
/// 真实目录树 `<tmp>/accept-demo/.worktrees/skill-demo` + 配为项目根,
/// 真实 zsh 宿主(cwd=worktree)拉起 3 个真实 node 忙循环(cwd 继承)。
/// node ∈ dev 名单、cwd 命中项目根下的 `.worktrees/skill-demo`
/// → 应归组为 "accept-demo @ skill-demo",组 CPU% = 忙循环之和(>100% 即证累加口径)。
/// (不用 /usr/bin/python3:它是 Xcode Python.app 的壳,App 归属层会先于项目归因
/// 抢走它——三层顺序的正确行为,恰好不适合做项目组代理。)
///
/// 走的是**完全真实的代码路径**(与弹窗同一条数据管线):
/// LiveProcessSource 真实采样 → CPUDiffer 真实差分 → GroupingPipeline 真实归组
/// → DrilldownState 真实下钻(cwd / argv / 父链面包屑)→ KillAction 真实处置。
/// 杀完整组后复扫:组员从进程表消失。
final class AcceptanceAnchorEndToEndTests: XCTestCase {
    private let source = LiveProcessSource()
    private let coreCount = ProcessInfo.processInfo.activeProcessorCount

    /// 轮询采样直到谓词命中或超时;返回命中的快照。
    private func sweepUntil(
        timeout: TimeInterval = 8,
        _ predicate: (ProcessSnapshot) -> Bool
    ) -> ProcessSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = source.snapshot()
            if predicate(snapshot) { return snapshot }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// 找真实 node:登录 shell 的 PATH → 常见安装位 → fnm 目录。
    /// 都没有则跳过(环境依赖型 E2E,不硬失败)。
    private func nodeExecutableURL() throws -> URL {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/bin/zsh")
        lookup.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        lookup.standardOutput = pipe
        lookup.standardError = Pipe()
        if let _ = try? lookup.run(), lookup.waitUntilExitWithTimeout(5),
           lookup.terminationStatus == 0
        {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        for candidate in [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ] where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        let fnmVersions = URL(fileURLWithPath: NSHomeDirectory() + "/.local/share/fnm/node-versions")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: fnmVersions,
            includingPropertiesForKeys: nil
        ).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            for version in versions {
                let node = version.appendingPathComponent("installation/bin/node")
                if FileManager.default.isExecutableFile(atPath: node.path) { return node }
            }
        }
        throw XCTSkip("本机找不到 node——验收锚点 E2E 需要一个 dev 名单里的真实可执行文件")
    }

    /// 项目根的最终路径(解析全部符号链接)。必须用 realpath(3):macOS 的
    /// /var、/tmp 是根卷符号链接,URL.resolvingSymlinksInPath() 不解析它们,
    /// 而真实进程 cwd(PROC_PIDVNODEPATHINFO)是 /private/var/… 全解析形态——
    /// 项目归因是纯路径前缀匹配,根必须是同一种形态才能命中。
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func testAnchorScenarioGroupDrilldownAndKillThroughRealPipeline() throws {
        // 1. 真实项目树:项目根 = <tmp>/…/accept-demo,worktree = .worktrees/skill-demo。
        //    根路径经 realpath 全解析:真实进程 cwd(PROC_PIDVNODEPATHINFO)是
        //    /private/var/… 形态,项目归因是纯路径前缀匹配,根须同为全解析形态
        //    (设置窗的 NSOpenPanel 返回的即是这种形态)。
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-accept-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let repoPath = base.appendingPathComponent("accept-demo", isDirectory: true).path
        // 先建目录再 realpath(realpath 对不存在的路径返回 NULL)。
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: repoPath + "/.worktrees/skill-demo"),
            withIntermediateDirectories: true
        )
        let resolvedRepoPath = Self.realPath(repoPath)
        let worktreePath = resolvedRepoPath + "/.worktrees/skill-demo"
        defer { try? FileManager.default.removeItem(at: base) }

        // 2. 真实负载:zsh 宿主(cwd=worktree)拉起 3 个 node 忙循环子进程。
        //    宿主脚本落盘,避免引用转义;子进程 cwd 继承宿主 = worktree。
        //    负载降档(用户要求,2026-10-14):3 个循环、全程 ≈2.5s(远低于 20s 上限)、
        //    结束即清——断言组 CPU% > 100% 已足以证明"单核累加 + 项目归因"口径;
        //    400%+ 读数已在实机走查中见证过一次,不再作为回归门槛。
        let nodeURL = try nodeExecutableURL()
        let hostScript = base.appendingPathComponent("host.zsh").path
        try """
        for i in 1 2 3; do
          \(nodeURL.path) -e 'while(true){}' &
        done
        wait
        """.write(toFile: hostScript, atomically: true, encoding: .utf8)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = [hostScript]
        shell.currentDirectoryURL = URL(fileURLWithPath: worktreePath)
        XCTAssertNoThrow(try shell.run())
        let shellPID = shell.processIdentifier
        // 失败路径也要清场:测试若在"整组处置"断言之前失败/被中断,忙循环会
        // 永远烧 CPU(前一轮跑挂后曾泄漏 4 个循环烧了整夜)。双保险——
        // ① pkill -P 按父 pid 清宿主的存活子进程(覆盖"组员尚未被发现"的窗口);
        // ② 逐个 SIGTERM 采样中见过的组员 pid(覆盖"宿主已死、组员被重挂"的情形)。
        var loopPIDs = Set<pid_t>()
        defer {
            let sweep = Process()
            sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            sweep.arguments = ["-TERM", "-P", String(shellPID)]
            try? sweep.run()
            _ = sweep.waitUntilExitWithTimeout(5)
            for pid in loopPIDs where pid != getpid() {
                kill(pid, SIGTERM)
            }
            if shell.isRunning { shell.terminate() }
            shell.waitUntilExit()
        }

        // 3. 与弹窗同一条管线:GroupingPipeline 喂真实项目根(= 设置窗持久化的值)。
        var pipeline = GroupingPipeline(
            configuration: GroupingConfiguration(
                projectRoots: [resolvedRepoPath],
                bundleDisplayName: BundleDisplayNameReader.shared.displayName
            ),
            displayLimit: GroupingPipeline.defaultDisplayLimit
        )

        // 4. 等真实采样看到 3 个以宿主为父的 node(锚点负载就位)。
        func loopMembers(in snapshot: ProcessSnapshot) -> [RawProcess] {
            let members = snapshot.processes.filter {
                $0.parentPID == shellPID
                    && ($0.executablePath ?? "").hasSuffix("/node")
            }
            loopPIDs.formUnion(members.map(\.pid)) // 记给失败路径清场用
            return members
        }
        let settled = try XCTUnwrap(
            sweepUntil { loopMembers(in: $0).count == 3 },
            "真实采样应在 8s 内看到 zsh 宿主(pid \(shellPID))的 3 个 node 子进程"
        )
        XCTAssertEqual(loopMembers(in: settled).count, 3)

        // 5. 两轮真实采样 + 差分(首轮登记出生,CPU 按第二轮差分——与 app 同节奏)。
        _ = pipeline.update(snapshot: settled, processCPU: [])
        Thread.sleep(forTimeInterval: 2.0)
        let second = source.snapshot()
        let diff = CPUDiffer.diff(
            previous: settled,
            current: second,
            logicalCoreCount: coreCount
        )
        let groups = pipeline.update(snapshot: second, processCPU: diff.processCPU)

        // 6. 锚点断言:项目组 "accept-demo @ skill-demo" 在 Top-5,组 CPU% 为循环之和。
        //    阈值守 >100%:两个及以上满核循环即达成,证明单核累加口径(降档后门槛)。
        let anchor = try XCTUnwrap(
            groups.first(where: { $0.name == "accept-demo @ skill-demo" }),
            "应归组出 \"accept-demo @ skill-demo\",实际:\(groups.map(\.name))"
        )
        XCTAssertEqual(anchor.category, .project)
        XCTAssertGreaterThan(anchor.cpuPercent, 100, "忙循环之和的组 CPU% 应超单核(累加口径)")
        XCTAssertEqual(anchor.processes.count, 3, "组员 = 3 个 node(宿主 zsh 非 dev,不入项目组)")

        // 7. 下钻断言(工单 06 验收面):cwd / argv / 面包屑走真实数据。
        let drilldown = DrilldownState(
            snapshot: second,
            lineage: pipeline.lineage,
            processCPU: diff.processCPU
        )
        for process in anchor.processes {
            XCTAssertEqual(
                process.cwd, worktreePath,
                "忙循环 cwd 应继承宿主 = worktree(spec:项目归因 cwd 优先)"
            )
            XCTAssertFalse(process.argv.isEmpty, "KERN_PROCARGS2 应取到完整 argv")
        }
        let rows = drilldown.rows(for: anchor)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.name), Array(repeating: "node", count: 3), "行名 = 可执行文件名")
        // 引擎契约:组内进程按 CPU% 降序——忙循环各自满核,互差在噪声内。
        let rowCPUs = rows.map(\.cpuPercent)
        XCTAssertGreaterThan(rowCPUs.min() ?? 0, 0, "忙循环都应有正 CPU%")
        XCTAssertLessThanOrEqual((rowCPUs.max() ?? 0) - (rowCPUs.min() ?? 0), 60)

        let topPID = try XCTUnwrap(rows.first?.pid)
        let detail = try XCTUnwrap(drilldown.detail(for: topPID), "点进程行应能展开详情")
        XCTAssertTrue(
            detail.process.argv.contains("while(true){}"),
            "完整 argv 应含忙循环命令体,实际:\(detail.process.argv)"
        )
        // 面包屑:"node ← zsh(宿主)← … ← 有归属祖先/launchd"。
        // 测试进程(拉起宿主者)在 Pulse.app bundle 内 → 终点是它,与锚点
        // "rustc ← cargo ← node ← Zcode" 同形;否则终点为 launchd。
        XCTAssertTrue(
            detail.parentChainText.contains("node"),
            "面包屑应含进程自身,实际:\(detail.parentChainText)"
        )
        XCTAssertTrue(
            detail.parentChainText.contains("zsh"),
            "面包屑应含拉起它的 zsh 宿主,实际:\(detail.parentChainText)"
        )

        // 8. 整组处置(工单 08 验收面):真实 SIGTERM,组员全灭、复扫消失。
        let report = KillReport(outcomes: KillAction.terminate(
            anchor.killTargets,
            excluding: getpid(),
            service: LiveKillService()
        ))
        XCTAssertFalse(report.hasFailures, "整组处置应全部投递成功:\(report.failureAlertMessage)")
        shell.waitUntilExit() // 3 个子进程死后 zsh `wait` 返回,宿主自然退出
        let after = try XCTUnwrap(
            sweepUntil { loopMembers(in: $0).isEmpty },
            "处置后复扫:3 个 node 应从进程表消失"
        )
        XCTAssertTrue(loopMembers(in: after).isEmpty)
    }
}

private extension Process {
    /// 带超时的 waitUntilExit(防登录 shell PATH 查询挂死测试)。
    func waitUntilExitWithTimeout(_ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isRunning
    }
}
