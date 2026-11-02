# 01: 资源告警经 NemoNotch 弹外部 toast(点名项目/应用组与进程)

**What to build:** 四类告警(系统负载 / 组 CPU / 新组内存 / 磁盘不足)触发时,经本机 NemoNotch 外部 toast API(公开契约 v1)在刘海下弹卡:标题点名承载组,正文列前三名进程与 CPU%/内存;持续状态卡(同 key 整卡替换);点击激活 Pulse;设置页「投递渠道」开关(默认开,规则开关为主闸门);任何失败 fire-and-forget 不影响主流程。

**Status:** done(2026-11-02,develop@bab8241;NemoNotch HookServer bug 由用户自修后终验通过)

- [x] PulseCore 归因纯函数(触发当轮组排行 × 进程差分 → 承载组 + 前三名;内存类按足迹重排;磁盘/dev server 无归因不硬造)
- [x] 契约载荷 + 文案拼装(key 消毒 `::` 钳 128;title 120 / body 280;请求体封套键名单测钉死)
- [x] Live 发送器(重读 hook-port/hook-token;3s 超时;连接失败重读端点重试一次;4xx 记日志不重试;令牌缺失静默跳过)
- [x] AlertCenter 第四出口(前三路不动;onRound 暂存同轮组上下文供归因)
- [x] 设置页「投递渠道」Toggle + AlertSettingsStore 持久键 `alertNemoNotchToastEnabled`(默认开)
- [x] 单测 22 例(归因 7 + 文案 9 + 出口接线 3 + 端点发现 3);全量 941 例
- [x] 真机管道验证:systemLoad 阈值临时 5% → 告警准时触发(读数 51.65%)、归因正确(「pulse」组)、toast 按契约发出——**被 NemoNotch 服务端 CRLF 字形簇 bug 误拒 400**(`hasCompleteHTTPRequest` 对两段式发送恒真;curl 单段掩盖,curl 验收全过)
- [x] 终验(2026-11-02 14:20):NemoNotch 修复后两段式 / URLSession 首发均 200;阈值临时 5% → 14:20:05 告警触发(读数 70.9%)→ toast 发出,两端日志零拒绝 / 零未送达;阈值已还原 70

## Comments

- **拍板(2026-11-01)**:范围 = A + 磁盘不足(四类,dev server 不进);渠道开关默认开(规则本身默认全关 = 主闸门);持续状态卡(同 key 覆盖不堆叠)。
- **交付**:develop@`7c36be0`(feat/nemonotch-toast 合并,941 例;宿主测试在 `.worktrees/` 下先因 NSLock-in-async 编译错挂——`/tmp` 退路同错可见,修复后全绿;顺手确认 `.worktrees/` 本轮无挂死病)。
- **NemoNotch bug 波及面**:`/v1/toast` 对所有 URLSession 客户端不可用 + `/hook` >64KB 事件被截断丢弃(另一会话 2026-11-01 17:57–17:59 三连实锤)。修一行(`firstIndex(of: "\r")` → `range(of: "\r\n")`),已隔离验证;报告含复现探针与回归测试清单。
- **遗留改进已入**:被拒日志带 reason(实战少记它多绕半小时)。
- **野外实证(修复前日志)**:2026-11-02 10:32 / 11:18 两次真实 100% 负载告警,标题已点名 `octok-client @ coding-agent-full-read` / `@ tui-skills-search`——归因在真实负载下成立(当时被服务端 bug 拒,修复后同链路通)。
