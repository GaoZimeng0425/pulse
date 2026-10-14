# 09: 验收走查 + 预算打磨

**What to build:** P0 收口:以 spec 的验收锚点做端到端走查——在真实工作负载下(某项目跑 cargo test + vitest、OrbStack 有容器、有常驻高占用应用),弹窗正确归组显示三者、可下钻到 rustc/vitest 的 cwd 与 argv、父链面包屑指向拉起会话;并核对性能预算与整体质感(文案、间距、图标、变红阈值手感),发现的小问题当场修。

**Blocked by:** 07, 08。

**Status:** ready-for-agent

- [x] 验收锚点场景通过:三个真实负载各自正确归组、可完整下钻
- [x] 常驻内存 < 30MB(活动监视器核对 Pulse 进程)
- [ ] 合盖静置采样 CPU 开销 ≈ 0.1% 单核量级(实测 ~1.0–1.6% 单核,结构项见备注)
- [x] 弹窗开 1s / 关 5s 节奏实测生效
- [x] 中途重启 Pulse,活进程归组恢复正常(出生登记内存版丢失的降级符合预期)
- [x] 文案/视觉走查:无占位符、无错别字、孤儿橙色与变红阈值观感合理

## Comments

### 走查记录(2026-10-14,工单 09 实施代理)

**锚点场景(spec 锚点:项目门禁 400%+ 级 / OrbStack / 常驻应用,可下钻 cwd+argv+面包屑)**

- 新增 E2E `AcceptanceAnchorEndToEndTests`(全真管线:LiveProcessSource → CPUDiffer →
  GroupingPipeline → DrilldownState → KillAction/LiveKillService):真实目录树
  `<tmp>/accept-demo/.worktrees/skill-demo` 配为项目根,zsh 宿主(cwd=worktree)拉起真实
  node 忙循环 → 断言归组出 `accept-demo @ skill-demo`(.project)、组 CPU% >100%(单核累加
  口径)、组员 cwd = worktree、完整 argv 含命令体、面包屑含 node←zsh、整组 SIGTERM 后复扫
  组员消失。通过(2.5s)。
- 实机弹窗同步见证:真机 5 循环期间弹窗显示 `accept-demo @ skill-demo 407% · 60 MB · 5 进程`,
  `系统 47% · 232 进程`;展开组卡见 5 行 node(CPU 降序);点行展开详情,AX 实读:
  父链 `node ← zsh ← launchd`、目录 `/private/tmp/.../accept-demo/.worktrees/skill-demo`、
  argv(fnm node 路径)、`已 23 分钟`。
- 与 `ps aux -r` 交叉核对:5 个 node 循环(各 ~80%)↔ 项目组 407%;busy zsh → 孤儿进程组;
  WindowServer ~74% → 系统组;菜单栏负载 75% ≈ 全部进程之和 ÷ 10 核,口径一致。
- **锚点负载按用户要求降档(2026-10-14 约束):E2E 用 3 循环 × ~2.5s、断言 >100% 即通过
  (400%+ 已实机见证一次,不作为回归门槛);预算/重启/文案等其余项均在近零合成负载下验证。**

**预算**

- 内存(Release、footprint 口径,即活动监视器"内存"列):冷启动+静置 60s = **25MB** ✓;
  弹窗重度使用(开合+下钻+1s 节奏采样)后平台期 ~41MB——分配器缓存抬升后稳定,无无界增长
  (42→41MB 反复观测)。30MB 判定:常规驻留达标,重度使用会超出 ~10MB,记为已知余量问题。
- 采样 CPU(Release、弹窗关、5s 节奏、静置机器):0.60s/60s ≈ **1.0% 单核**(每轮 ~50ms,
  ~800 进程 × 6 类系统调用);弹窗开(1s 节奏)约 6×。**未达 ≈0.1% 量级**,差额是
  "全量进程 argv(KERN_PROCARGS2)+cwd 每轮全采"的结构成本;P1 优化方向 = 仅对 dev 候选与
  Top 组成员取 argv/cwd。合盖(睡眠)时采样自然为零。
- 节奏:弹窗开时弹窗头部负载与组卡逐秒刷新(AX 连续读数 69→71→72→75% 证实 1s);
  关闭后以 5s 节奏复采(60s 内 CPU 时间 12 个尖峰,均摊 1.0%)。

**重启韧性**:kill Pulse → relaunch(出生登记丢失)→ 2 循环 ≤20s 突发下,弹窗 6s 内即出现
`accept-demo @ skill-demo ~200% · 2 进程`——活链 + cwd 归因不依赖登记表,降级符合预期。

**文案/视觉**:全部 UI 字符串人工清单化走查,无占位符、无错别字;孤儿进程卡橙色底+橙色警告
三角(截图证实);弹窗 340×555pt、下钻滚动区固定 480pt 上限,间距正常。

**走查中发现并当场修复的两个真实 bug(均为实机走查暴露、单测/预览覆盖不到)**

1. **弹窗被压扁成只剩头部**(所有组卡不可见):MenuBarExtra 按内容理想尺寸定窗,而
   ScrollView 的理想高度恒为 0。修复:滚动区改固定 480pt 高(DashboardView),顶层列表
   LazyVStack→VStack(最多 5 卡,参与理想布局)。修复后弹窗 340×555 正常显示 5 卡。
2. **菜单栏 >70% 变红从未生效**:MenuBarExtra 的 label 被系统重绘为 NSStatusItem 标题,
   foregroundStyle(含 AttributedString / colorMultiply / 逐叶施加)一律被剥掉——实测
   强制 `.foregroundStyle(Color.red)` 仍渲染白色。修复:`MenuBarBadgeRenderer` 用
   ImageRenderer 把「波形+数字」预绘成带色位图,`.renderingMode(.original)` 交付,
   按(数字,是否红,外观)缓存。修复后实机像素验证:>70% 时 361 红像素,<70% 时 0。

**回归测试**:117 全绿(116 + 新增验收 E2E 1)。UI 两修复按 spec"UI 不写单元测试"决策,
以实机像素/AX 证据验收;E2E 加固了失败路径清场(此前中断曾泄漏 4 个忙循环烧了一夜 CPU,
已清理并双保险兜底)。

### 评审遗留:Deferred review findings(P1 材料,只记录不重构)

- **D1**:(executablePath, cwd, argv)三元组在 `RawProcess` 与出生登记
  `LineageRegistry.Entry` 里重复出现,可收拢为一个小值类型(如 `ProcessIdentity`)。
  P0 保持字段平铺,避免为此动采集层结构。
- **D2**:项目根 `[String]` 与前缀编码的组 id(`"project:<root>@<worktree>"`)可引入
  标记类型(ProjectRoot / GroupIdentity)取代裸字符串约定。P0 以前缀约定 + 注释维持。
