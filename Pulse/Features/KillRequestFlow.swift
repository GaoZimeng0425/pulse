import AppKit
import PulseCore

// MARK: - 处置确认对话框(工单 08)

/// 确认对话框(NSAlert):"确认后才杀"的唯一关口。
/// **取消按钮先添加 = NSAlert 默认按钮**——默认焦点与回车键都落在"取消"(防误触);
/// "结束"按钮无键盘等价键,只有明确点击才执行。
/// 文案构造在 KillCopy(纯函数,单测见 KillCopyTests);焦点次序属 UI,按 spec 以手动验收。
enum KillConfirmationDialog {
    @MainActor
    static func confirm(title: String, informativeText: String, actionTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: KillCopy.cancelButtonTitle) // 先加 = 默认焦点(回车 = 取消)
        let actionButton = alert.addButton(withTitle: actionTitle)
        actionButton.keyEquivalent = "" // 不给"结束"任何键盘触发
        return alert.runModal() == NSApplication.ModalResponse.alertSecondButtonReturn
    }
}

// MARK: - 处置编排与失败弹窗(工单 08;P0.5-01 起弹窗与主窗口共用)

/// 处置请求编排:确认对话框把关 → 确认后才发信号;返回失败汇总——
/// 全成功返回 nil 保持安静(行 / 组消失交给下轮采样自然反映)。
/// 原为 DashboardView 私有逻辑,工单 P0.5-01 主窗口需要同一流程,抽出共用;
/// 对话框构造(KillCopy)、焦点次序与"有失败才弹"口径与 P0 完全一致。
@MainActor
enum KillRequestFlow {
    /// 进程详情"结束进程"(单目标,确认时点名 name+pid)。
    static func endProcess(_ target: KillTarget, monitor: SystemMonitor) -> KillReport? {
        let targets = [target]
        let confirmed = KillConfirmationDialog.confirm(
            title: KillCopy.confirmationTitle(for: targets),
            informativeText: KillCopy.confirmationMessage(for: targets),
            actionTitle: KillCopy.singleActionTitle
        )
        guard confirmed else { return nil }
        let report = monitor.terminate(targets)
        return report.hasFailures ? report : nil
    }

    /// 组卡"结束整组"(确认时列进程数)→ 对最新一轮采样的组员逐个 SIGTERM。
    static func endGroup(_ group: ProcessGroup, monitor: SystemMonitor) -> KillReport? {
        let confirmed = KillConfirmationDialog.confirm(
            title: KillCopy.groupConfirmationTitle(groupName: group.name),
            informativeText: KillCopy.groupConfirmationMessage(processCount: group.processes.count),
            actionTitle: KillCopy.groupActionTitle
        )
        guard confirmed else { return nil }
        let report = monitor.terminateGroup(id: group.id)
        return report.hasFailures ? report : nil
    }

    /// dev server 卡"全部停止"(工单 08):一次确认列出全部目标,确认后逐个
    /// SIGTERM;确认流与单进程/整组同一 NSAlert 关口,绝不自动杀。
    static func stopAll(_ targets: [KillTarget], monitor: SystemMonitor) -> KillReport? {
        guard !targets.isEmpty else { return nil }
        let confirmed = KillConfirmationDialog.confirm(
            title: KillCopy.stopAllConfirmationTitle,
            informativeText: KillCopy.confirmationMessage(for: targets),
            actionTitle: KillCopy.stopAllActionTitle
        )
        guard confirmed else { return nil }
        let report = monitor.terminate(targets)
        return report.hasFailures ? report : nil
    }
}
