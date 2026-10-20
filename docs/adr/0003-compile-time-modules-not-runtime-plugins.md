# 功能以编译期模块组织,不做进程外插件

产品定位单人自用的菜单栏监视器,但功能面会持续增长(CPU/内存/磁盘/网络指标、dev server 侦测、告警、历史、MCP)。决定:每个"服务"(指标提供者、功能模块、UI 卡片)以独立 Swift 模块 + 小协议扩展点(如 MetricProvider)组织,经注册表组装、可在设置中开关——"模块即插件"。不做进程外真插件(独立二进制或 dylib 运行时加载):采样是每 1–5 秒一轮的微秒级 syscall,跨进程 IPC 的开销与复杂度不成比例;ad-hoc 签名下动态加载插件有签名与权限负担;且自用工具不存在第三方生态诉求,对外的开放面将来由 MCP server(v2)承担。

时机:P0 不引入扩展抽象(仅保留既定的 `ProcessSource` 接缝);P1 第一个功能模块落地时定义扩展点,dev server 侦测、告警、SQLite 历史各自成模块。

澄清(评审 T1):`ProcessSource`、`KillService` 这类协议是**编译期测试注入接缝**——为让纯逻辑可单测而存在,产品运行期只有一个真实现、不做运行时替换;"编译期测试接缝"与"可运行时装卸的插件"是两回事,后者仍按本 ADR 不做。

兑现(2026-10-20,arch-review-2026-10-18/01):扩展点为 `MonitorFeature`(`Pulse/MonitorSpine.swift`),告警 / dev server / 网络 / 磁盘 / 电池 / 模块排行 / 历史七个功能模块各为「@Observable 薄壳 + 纯值内核」,由工厂构造、以注册列表(`MonitorFeatures`)交给 SystemMonitor;SystemMonitor 只剩共享归组主干(RoundSpine)与派发。模块间不互持引用,经宿主广播事件通信。「模块」此时仍指同一 target 内的类型边界;编译器守门的 SPM 模块边界见 arch-review-2026-10-18/05(PulseCore)。设置中开关模块未做(无需求)。
