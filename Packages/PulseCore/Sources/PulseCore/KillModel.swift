import Darwin
import Foundation

// 结束进程的纯逻辑:处置接缝、编排、目标 / 结果 / 文案。发信号的 LiveKillService 在 app target(KillService.swift)。

/// 处置服务接缝:对单个 pid 发信号。协议之上全部纯逻辑(KillAction);
/// 单测用假实现断言目标 / 顺序 / 失败隔离,真实现 `LiveKillService` 调 kill(2)。
///
/// 接缝说明(评审 T1):与 `ProcessSource` 一样,这是项目为单测预留的
/// **第二个编译期测试注入接缝**——目的是让编排逻辑可离线断言,
/// 生产运行期只有一个真实现、不做运行时替换;这不是插件机制
/// (见 ADR-0003:编译期测试接缝 ≠ 运行时插件)。
public protocol KillService: Sendable {
    /// 向 pid 发送信号,同步返回投递结果(kill(2) 不阻塞,无需异步)。
    func send(signal: Int32, to pid: pid_t) -> KillSignalResult
}

/// kill(2) 的结果口径:投递成功 / 失败原因(errno 映射,可读中文文案的原料)。
public enum KillSignalResult: Equatable, Sendable {
    case delivered
    case failed(KillSignalFailure)
}

/// 单个 pid 发信号失败的 errno 归类:权限不足(root 进程)/ 已退出 / 其它。
public enum KillSignalFailure: Equatable, Sendable {
    case permissionDenied // EPERM
    case noSuchProcess // ESRCH
    case other(Int32)

    /// 每个目标的可读失败提示(spec:逐对象可读、不静默假装成功)。
    public var message: String {
        switch self {
        case .permissionDenied: "无权限结束(可能属于 root)"
        case .noSuchProcess: "进程已退出"
        case let .other(errno): "系统调用失败(errno \(errno))"
        }
    }
}

/// 一次处置的目标:显示名 + pid——确认对话框列对象、结果汇总逐目标提示,
/// 都以它为单元。
public struct KillTarget: Equatable, Hashable, Sendable, Identifiable {
    public let pid: pid_t
    public let name: String

    public var id: pid_t {
        pid
    }

    public init(pid: pid_t, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// 确认后的处置执行(纯逻辑):逐目标发 SIGTERM。两条硬约束——
/// ① 永不信号 `ownPID`(Pulse 自身,即使它出现在组员里),排除发生在发信号之前;
/// ② 单个目标失败(root 属主 / 已退出)不中断其余,各目标各得其结果。
public enum KillAction {
    /// 结束信号:SIGTERM——先给进程优雅退出的机会(spec 实现决策)。
    public static let terminationSignal = SIGTERM

    /// 逐目标执行。目标顺序只影响尝试次序,不影响结果集合。
    public static func terminate(
        _ targets: [KillTarget],
        excluding ownPID: pid_t,
        service: some KillService
    ) -> [KillOutcome] {
        targets
            .filter { $0.pid != ownPID }
            .map { target in
                KillOutcome(
                    target: target,
                    result: service.send(signal: terminationSignal, to: target.pid)
                )
            }
    }
}

/// 单个目标的处置结果:目标 + 投递结果;`message` 为逐目标可读中文文案。
public struct KillOutcome: Equatable, Sendable, Identifiable {
    public let target: KillTarget
    public let result: KillSignalResult

    public var id: pid_t {
        target.pid
    }

    public var succeeded: Bool {
        result == .delivered
    }

    public var message: String {
        switch result {
        case .delivered: "已发送结束信号"
        case let .failed(failure): failure.message
        }
    }

    public init(target: KillTarget, result: KillSignalResult) {
        self.target = target
        self.result = result
    }
}

public extension RawProcess {
    /// 单进程处置目标:显示名与下钻行同口径(可执行 basename → argv[0] → "pid N")。
    var killTarget: KillTarget {
        KillTarget(
            pid: pid,
            name: PulseFormat.processName(executablePath: executablePath, argv: argv, pid: pid)
        )
    }
}

public extension ProcessGroup {
    /// 整组处置目标清单:组内全部存活成员(引擎契约:组来自最近一轮采样)。
    var killTargets: [KillTarget] {
        processes.map(\.killTarget)
    }
}

/// 处置相关中文文案:确认对话框与结果汇总统一从这里出。
/// "不主动杀、确认后才杀"——对话框文案必须明确列出将结束的对象
/// (单进程 name+pid / 整组进程数),让用户确认的就是将发生的事。
public enum KillCopy {
    public static let cancelButtonTitle = "取消"
    public static let singleActionTitle = "结束进程"
    public static let groupActionTitle = "结束整组"

    /// 单进程确认标题:"结束进程 rustc(pid 100)?"——name+pid 点名对象。
    public static func confirmationTitle(for targets: [KillTarget]) -> String {
        let described = targets.map { "\($0.name)(pid \($0.pid))" }.joined(separator: "、")
        return "结束进程 \(described)?"
    }

    /// 单进程确认内容:说明发送的信号(SIGTERM,可保存后退出)。
    public static func confirmationMessage(for targets: [KillTarget]) -> String {
        let described = targets.map { "\($0.name)(pid \($0.pid))" }.joined(separator: "、")
        return "将向 \(described)发送结束信号(SIGTERM),进程可保存后退出。"
    }

    /// 整组确认标题:点组名。
    public static func groupConfirmationTitle(groupName: String) -> String {
        "结束整组 \(groupName)?"
    }

    /// 整组确认内容:列出进程数(spec:对话框列出进程数)。
    public static func groupConfirmationMessage(processCount: Int) -> String {
        processCount == 1
            ? "将结束该组的 1 个进程,并发送结束信号(SIGTERM)。"
            : "将结束该组的 \(processCount) 个进程,每个都会收到结束信号(SIGTERM)。"
    }

    // MARK: dev server「全部停止」(工单 08)

    /// 全部停止按钮文字。
    public static let stopAllActionTitle = "全部停止"

    /// 全部停止确认标题(内容复用多目标 confirmationMessage,逐个点名 name+pid)。
    public static let stopAllConfirmationTitle = "停止全部 dev server?"
}

/// 一次处置的汇总:UI 结果弹窗的原料。有失败才浮出(全成功安静——
/// 行消失交给下轮采样,不静默假装成功,也不报喜打扰)。
public struct KillReport: Equatable, Sendable {
    public let outcomes: [KillOutcome]

    public init(outcomes: [KillOutcome]) {
        self.outcomes = outcomes
    }

    public var failures: [KillOutcome] {
        outcomes.filter { !$0.succeeded }
    }

    public var hasFailures: Bool {
        !failures.isEmpty
    }

    /// 全部目标都失败(空结果不算:那意味着没有要结束的对象)。
    public var allFailed: Bool {
        !outcomes.isEmpty && failures.count == outcomes.count
    }

    public var failureAlertTitle: String {
        allFailed ? "未能结束任何进程" : "部分进程未能结束"
    }

    /// 逐目标失败提示;部分失败时前缀一行成功/失败计数。
    public var failureAlertMessage: String {
        let lines = failures.map { failure in
            "• \(failure.target.name)(pid \(failure.target.pid)):\(failure.message)"
        }
        if allFailed {
            return lines.joined(separator: "\n")
        }
        let succeeded = outcomes.count - failures.count
        return "已结束 \(succeeded) 个,\(failures.count) 个未能结束:\n"
            + lines.joined(separator: "\n")
    }
}
