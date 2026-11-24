# 07: root 助手日志落点收紧

**What to build:** 修复 REPORT 中7:特权 daemon 以固定路径写 `/tmp/pulse-helper-debug.log`,跟随符号链接、默认权限,给只读助手平白增加文件写原语并泄露全机进程名。

**Status:** ready-for-agent

证据见 `../REPORT.md` §中7:`Packages/PulseHelper/Sources/PulseHelperCore/Collector.swift:7-18`,由 `collect()` 的失败/轮次分支触发。

**Agent Brief:**
1. 日志改为 root 专属位置(如 `/Library/Logs/Pulse/helper.log`,目录 0700、文件 0600),或 `mkstemp` 生成不可预测文件名;打开时 `O_NOFOLLOW` 并校验 `lstat` 为常规文件且属主 root;写入失败静默不崩。
2. Release 构建默认关闭该诊断日志(可用编译条件或环境变量显式开启),诊断用途仍可经用户主动开启。
3. 确认改动不触碰 ADR-0009 的只读承诺:助手仍只有 powermetrics 子进程 + `/var/run` 快照 + 自己的日志三处写,绝不加用户数据删除/改写通道。

**验收:** 非特权用户预置 symlink 无法让 root 写任意文件;日志不再世界可读;单测/构建绿。

## 核实(2026-11-24)

真但被夸大,降为低。「泄露进程名」不成立(日志只写计数与错误码);内容不可控,只能给 root 文件追加垃圾行,且需他人抢在首写前放 symlink。ADR-0009 引用不对口(那篇讲清理不经 root 助手)。**Brief 收窄**:Release 默认关掉该日志或改 os_log,即可省掉 O_NOFOLLOW/lstat 校验。
