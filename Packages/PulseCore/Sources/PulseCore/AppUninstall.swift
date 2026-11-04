import Foundation

// MARK: - 卸载执行编排(p4-uninstaller/03;ADR-0008/0009/0010 的卸载域投影)

//
// 纯值编排,零 IO:边界动作(废纸篓 / 永久删除 / brew / 运行重查 / 收据交叉核对)
// 全部闭包注入,测试喂 spy。判断类逻辑全在这——先 brew 后文件(brew 失败 = 本次
// 零文件动作,Q9)、逐项失败跳过如实报数、改道核对(Q11)、删除前重查(判定不缓存)。
//
// 去向映射(spec + ADR-0010):
//   非 brew + 默认      app 与残留 → 废纸篓
//   非 brew + 彻底删除  app 与残留 → 永久删除(.direct)
//   brew + 默认         app → brew uninstall(永久,.brew);勾选残留 → 废纸篓
//   brew + 彻底删除     brew --zap;app 与「收据 zap 声明的勾选项」→ .brew;
//                       勾选中 zap 未覆盖的残留 → 我们直删(.direct)
//   brew 内部删除不透明:exit 0 即按声明记 .brew(防御纪律的边界,注释如实);
//   我们自己批次的回执逐项核对,执行器没报到的按失败记,不默认成功。

/// 一次卸载的执行计划(确认弹窗与执行共用的单一事实源;Q6/Q9 的输入)。
public struct AppUninstallPlan: Sendable, Equatable {
    public let appPath: String
    public let appName: String
    public let appBytes: Int64?
    /// brew 徽标判定(票 01 的收据索引,离线)。
    public let caskName: String?
    /// 「彻底删除」勾选(默认不勾、每次展开重置)。
    public let permanent: Bool
    /// 用户勾选的残留行(默认全不勾)。
    public let leftoverItems: [AppLeftoverRow]
    /// 该 cask 收据 zap 段声明的路径(判「brew 覆盖 vs 我们直删」)。
    public let receiptZapPaths: [String]

    public var isBrew: Bool {
        caskName != nil
    }

    public init(
        appPath: String,
        appName: String,
        appBytes: Int64?,
        caskName: String?,
        permanent: Bool,
        leftoverItems: [AppLeftoverRow],
        receiptZapPaths: [String] = []
    ) {
        self.appPath = appPath
        self.appName = appName
        self.appBytes = appBytes
        self.caskName = caskName
        self.permanent = permanent
        self.leftoverItems = leftoverItems
        self.receiptZapPaths = receiptZapPaths
    }

    public var directoryName: String {
        (appPath as NSString).lastPathComponent
    }
}

/// brew 卸载子进程的结果(Live 侧 `LiveBrewUninstaller` 产出)。
public enum BrewUninstallResult: Sendable, Equatable {
    case success
    /// 本机没有 brew(徽标是离线收据判的,期间可能被卸载)。
    case brewMissing
    /// brew 存在但命令失败;message = 人话原因(stderr 尾部)。
    case failed(message: String)
}

/// 永久删除批次的回执(与 TrashRecycleOutcome 同构,deleted 无去向路径)。
public struct PermanentDeletionOutcome: Sendable, Equatable {
    public var deleted: Set<String>
    public var failures: [String: String]

    public init(deleted: Set<String> = [], failures: [String: String] = [:]) {
        self.deleted = deleted
        self.failures = failures
    }
}

/// 一次卸载的结局。
public enum AppUninstallTermination: Sendable, Equatable {
    /// 走完(含部分失败项);payload 为战报(落清理历史 + 完成横幅,Q10)。
    case completed(CleanRunReport)
    /// brew 缺失 / 命令失败:本次零文件动作(Q9:绝不回退文件删除)。
    case aborted(reason: String)
    /// 非 brew 应用动作时刻交叉核对发现归 brew 管,等用户选(Q11:改道提示)。
    case needsReroute(cask: String)
    /// 删除前重查发现 app 正在运行(判定不缓存)。
    case rejectedRunning
}

public enum AppUninstallRunner {
    /// - Parameters:
    ///   - rerouteAcknowledged: 用户在改道提示里选了「仍要直接删文件」后的重跑为 true;
    ///     首跑恒 false(核对发现归 brew 管即停,把选择权交回界面)。
    public static func run(
        _ plan: AppUninstallPlan,
        recycle: @Sendable ([String]) async -> TrashRecycleOutcome,
        deletePermanently: @Sendable ([String]) async -> PermanentDeletionOutcome,
        brewUninstall: @Sendable (_ cask: String, _ zap: Bool) async -> BrewUninstallResult,
        isAppRunning: @Sendable (String) -> Bool,
        crossCheckCask: @Sendable (String) async -> String?,
        rerouteAcknowledged: Bool = false,
        now: @Sendable () -> Date = { Date() }
    ) async -> AppUninstallTermination {
        let startedAt = now()
        // 删除前重查(在用保护 spec:判定不缓存,删前再判一次)。
        guard !isAppRunning(plan.appPath) else {
            return .rejectedRunning
        }

        if let cask = plan.caskName {
            return await runBrew(
                plan, cask: cask, recycle: recycle, deletePermanently: deletePermanently,
                brewUninstall: brewUninstall, startedAt: startedAt, now: now
            )
        }

        // 非 brew:动作时刻交叉核对收据(Q11)——徽标是清单构建时刻的快照,
        // 期间用户可能 brew install 了同名 cask;发现归 brew 管即交回界面。
        if !rerouteAcknowledged, let cask = await crossCheckCask(plan.directoryName) {
            return .needsReroute(cask: cask)
        }

        let paths = [plan.appPath] + plan.leftoverItems.map(\.path)
        // Swift 泛型不便在两个回执类型间条件分派,这里拆两支各自成行(防御逻辑同款)。
        if plan.permanent {
            let outcome = await deletePermanently(paths)
            let items = paths.enumerated().map { index, path in
                item(for: path, at: index, in: plan, outcome: receipt(for: path, from: outcome))
            }
            return .completed(CleanRunReport(startedAt: startedAt, finishedAt: now(), items: items))
        }
        let outcome = await recycle(paths)
        let items = paths.enumerated().map { index, path in
            item(for: path, at: index, in: plan, outcome: receipt(for: path, from: outcome))
        }
        return .completed(CleanRunReport(startedAt: startedAt, finishedAt: now(), items: items))
    }

    // MARK: brew 分支

    private static func runBrew(
        _ plan: AppUninstallPlan,
        cask: String,
        recycle: @Sendable ([String]) async -> TrashRecycleOutcome,
        deletePermanently: @Sendable ([String]) async -> PermanentDeletionOutcome,
        brewUninstall: @Sendable (String, Bool) async -> BrewUninstallResult,
        startedAt: Date,
        now: @Sendable () -> Date
    ) async -> AppUninstallTermination {
        // 先 brew:失败 = 本次零文件动作(勾选的残留一概不动,Q9)。
        let brew = await brewUninstall(cask, plan.permanent)
        switch brew {
        case .brewMissing:
            return .aborted(reason: "未找到 Homebrew——这个应用由它安装,请先安装 brew 或在 Finder 手动删除")
        case let .failed(message):
            return .aborted(reason: "Homebrew 卸载失败,本次未删除任何文件:\(message)")
        case .success:
            break
        }

        // app 本体恒走 brew(.brew 路由;文件由 brew 删除,不经我们手)。
        var items = [appItem(for: plan)]
        let zapSet = Set(plan.receiptZapPaths)
        var ownPaths: [String] = [] // 我们自己动手的批次(废纸篓或直删)

        for leftover in plan.leftoverItems {
            if plan.permanent, zapSet.contains(leftover.path) {
                // brew --zap 声明域:exit 0 即按声明记 .brew。brew 内部不透明,这是
                // 防御纪律的边界——我们只核对「声明过」,不假装核对过盘。
                items.append(leftoverItem(leftover, outcome: .permanentlyDeleted(route: .brew)))
            } else {
                ownPaths.append(leftover.path)
            }
        }

        if !ownPaths.isEmpty {
            // 回执按路径对账,批次结果不改变行的确认序(app 先、残留按勾选序)。
            let leftovers = plan.leftoverItems.filter { ownPaths.contains($0.path) }
            if plan.permanent {
                let outcome = await deletePermanently(ownPaths)
                for leftover in leftovers {
                    items.append(leftoverItem(leftover, outcome: receipt(for: leftover.path, from: outcome)))
                }
            } else {
                let outcome = await recycle(ownPaths)
                for leftover in leftovers {
                    items.append(leftoverItem(leftover, outcome: receipt(for: leftover.path, from: outcome)))
                }
            }
        }
        return .completed(CleanRunReport(startedAt: startedAt, finishedAt: now(), items: items))
    }

    // MARK: 回执与行构造

    /// 批次回执 → 某路径的 outcome;执行器没报到的按失败记,不默认成功(一期同款防御)。
    private static func receipt(for path: String, from outcome: TrashRecycleOutcome) -> CleanItemOutcome {
        if let destination = outcome.recycled[path] {
            return .recycled(destination: destination)
        }
        if let reason = outcome.failures[path] {
            return .failed(reason: reason)
        }
        return .failed(reason: "执行器未报告结果")
    }

    private static func receipt(for path: String, from outcome: PermanentDeletionOutcome) -> CleanItemOutcome {
        if outcome.deleted.contains(path) {
            return .permanentlyDeleted(route: .direct)
        }
        if let reason = outcome.failures[path] {
            return .failed(reason: reason)
        }
        return .failed(reason: "执行器未报告结果")
    }

    /// 行元数据(paths 的第 index 项:0 = app 本体,其后按勾选序)。
    private static func rowMeta(
        for index: Int,
        in plan: AppUninstallPlan
    ) -> (title: String, bytes: Int64, tier: CleanSafetyTier, ruleID: String) {
        if index == 0 {
            // 大小未知记 0(不伪造),对释放总量的贡献偏保守。
            return (plan.appName, plan.appBytes ?? 0, .safe, "app-uninstall")
        }
        let leftover = plan.leftoverItems[index - 1]
        return (
            leftover.site.plainTitle,
            leftover.sizeBytes ?? 0,
            leftover.isCheckFirst ? .checkFirst : .safe,
            "app-leftover"
        )
    }

    private static func item(
        for path: String,
        at index: Int,
        in plan: AppUninstallPlan,
        outcome: CleanItemOutcome
    ) -> CleanRunItem {
        let meta = rowMeta(for: index, in: plan)
        return CleanRunItem(
            path: path, title: meta.title, bytes: meta.bytes,
            tier: meta.tier, ruleID: meta.ruleID, outcome: outcome
        )
    }

    private static func appItem(for plan: AppUninstallPlan) -> CleanRunItem {
        CleanRunItem(
            path: plan.appPath, title: plan.appName,
            bytes: plan.appBytes ?? 0,
            tier: .safe, ruleID: "app-uninstall",
            outcome: .permanentlyDeleted(route: .brew)
        )
    }

    private static func leftoverItem(_ leftover: AppLeftoverRow, outcome: CleanItemOutcome) -> CleanRunItem {
        CleanRunItem(
            path: leftover.path, title: leftover.site.plainTitle,
            bytes: leftover.sizeBytes ?? 0,
            tier: leftover.isCheckFirst ? .checkFirst : .safe,
            ruleID: "app-leftover", outcome: outcome
        )
    }
}
