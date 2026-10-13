# 08: kill:单进程 + 整组

**What to build:** 处置能力,遵循"不主动杀、确认后才杀":进程明细行提供"结束进程"、组卡提供"结束整组"(枚举组内全部存活进程)。两者均弹确认对话框,明确列出将结束的对象;确认后发信号,弹窗在下一轮采样反映结果。系统类进程与无权结束的进程(如 root 的)失败时给出可读提示,不静默假装成功。

**Blocked by:** 06。

**Status:** ready-for-agent

- [x] 进程行"结束进程"→ 确认对话框 → 进程终止,列表下轮刷新消失
- [x] 组卡"结束整组"→ 确认对话框列出进程数 → 组内进程终止
- [x] 无权限结束的进程给出失败提示,不影响其余对象
- [x] 确认对话框默认焦点在"取消"(防误触)
- [x] 用一个自造的 sleep 进程组完成端到端验证(从下钻到 kill)

## Comments

- 2026-10-13 实现完成(commit 见 p0/08):`KillService` 协议 + `LiveKillService`(kill(2),errno→可读中文);`KillAction` 编排(SIGTERM、排除自身 pid、逐目标失败隔离);`KillCopy`/`KillReport` 确认与汇总文案;UI 为进程详情"结束进程"按钮 + 组卡 xmark.octagon"结束整组"按钮,NSAlert 确认(取消先添加 = 默认焦点,结束按钮无键盘等价键),有失败才弹汇总、全成功安静交给下轮采样。
- 端到端验证 `KillEndToEndTests`:自造 zsh + 3×sleep 300 真实进程组,LiveProcessSource 采样发现 → 下钻数据构目标 → KillAction+LiveKillService 发 SIGTERM → 4 进程全死(uncaughtSignal)→ 复扫消失。真实 EPERM 映射(launchd)与 ESRCH 映射(reaped pid)另有真实单测。
