# 02: 采集层:ProcessSource 接缝 + Live 实现

**What to build:** 项目唯一的 OS 测试接缝落地:定义 `ProcessSource`(采集一次快照的协议)与快照模型(原始进程:pid、ppid、可执行路径、argv、cwd、CPU 累计时间、内存、磁盘字节、启动时刻)。提供 `LiveProcessSource` 薄适配器,用探针(`docs/probe.swift`)已验证的 Darwin API 全集实现:`proc_listallpids`、`proc_pidpath`、`PROC_PIDTASKINFO`、`proc_pid_rusage`、`KERN_PROCARGS2`(跳过 execpath 再取 argv)、`PROC_PIDVNODEPATHINFO`(`vnode_info_path` 布局手写或引入少量 C 代码)、`KERN_PROC` 取 `kp_eproc.e_ppid`。附 `SyntheticProcessSource` 骨架(可注入合成进程树,后续票的测试地基)。以冒烟测试证明采集在本机真实可用。

**Blocked by:** 01(工程骨架与测试 target)。

**Status:** ready-for-agent

- [ ] 协议 + 快照模型定义完成,纯 Swift 值类型
- [ ] Live 实现一轮采集本机返回 >0 个进程,耗时毫秒级
- [ ] 冒烟测试:能读到本机 zsh/登录 shell 的可执行路径;能读到自身 argv 与 cwd
- [ ] KERN_PROCARGS2 解析跳过第一个字符串(execpath),argv 完整
- [ ] root 进程(如 pid 1)采集受限时静默降级,不崩溃不报错
- [ ] SyntheticProcessSource 可注入任意合成进程树(供 03/05 使用)

## Comments
