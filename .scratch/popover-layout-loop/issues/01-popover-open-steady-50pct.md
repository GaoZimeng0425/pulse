# 票 01:菜单弹窗打开期间主线程布局循环,自身稳态 ~50% 单核

- 状态:**ready-for-agent**(立票即分诊:复现+对照+采样定性已完成,见下)
- 日期:2026-10-28 晚
- 来源:用户在弹窗进程列表看到 Pulse 自身稳定 40-60%,追问三轮定位

## 现象(实测,非显示错误)

- 弹窗打开 → Pulse 自身真实 CPU **稳定 46-58%**(哨兵 2s 窗实录,
  21:51:47-21:52:29 每窗都在 46-58);关窗 2 秒内回落到 0-3%。
- 打开瞬间另见一窗 **300%**(多线程冷渲染爆发,21:51:45)。
- 对照:主窗口开着仅 ~4-9%——小弹窗反而贵一个数量级,病态。
- 哨兵全程日志:`pulse_popover_watch.log`(同目录);截图(用户供,
  弹窗内 Pulse 行 55%/142MB)。

## 采样定性

样本 `pulse_popover_sample.txt.gz`(弹窗开期间自动触发,5s/1942 样本):

- **主线程 37%(721/1942)陷在每显示周期一次的整树 Auto-Layout 递归**:
  `UpdateCycle DriverCore → CA::Transaction flush → NSDisplayCycleFlush →
  NSWindow layoutIfNeeded → NSView layoutSubtree…`层层重排;
- SwiftUI 渲染管线同步放大:AttributeGraph 树行 374(vs 主窗口开 180)、
  RenderBox 102(vs 14)、ImageRenderer 14(vs 9);
- 自家帧可见:MenuBarLoadLabel.body(PulseApp.swift:163)~24 样本、
  MenuBarBadgeRenderer.image(MenuBarBadge.swift:60)~22 样本;
- **弹窗内容非每帧源**:RankingListRow 等内容帧只按 5s tick 出现
  (协作采样队列 47/1942≈2.4%,nettop 50/1942≈2.6%,均为正常档)。

对照样本(主窗口开,同日上午,/tmp 原位):同一 UpdateCycle 链仅
91/3627≈**2.5%**——弹窗打开是唯一把布局推成连续循环的状态。

## 排除项

- root helper:15h 累计 6.35s CPU,全程空闲;
- pulse-mcp:每会话一进程各 ~0.6%,与弹窗无关;
- p4-cleaner(当晚新合入):未跑过扫描,日志 0 条;
- 稳态回归:关窗后 0-3%,基线健康(见 p3-root-mcp/04 票记档)。

## 疑根(待实施时定位到行)

弹窗打开期间,某物每显示周期把布局弄脏一次 → 全树重排 + CA 提交循环。
头号嫌疑:MenuBarExtra 徽标 label 在弹窗打开期间被逐帧重新求值/重绘
(每次 body 可能新建 NSImage 实例 → 状态项换图 → 重排)。
定位手段:SwiftUI `_printChanges` / AttributeGraph 失效追踪,弹窗开着时跑。

## 候选修法(按侵入度升序)

1. 徽标位图等值短路:显示值未变时复用同一 NSImage 实例(最小刀);
2. label 求值依赖收窄:body 只读迟滞后的稳定值,不读任何随帧/随弹窗态变的量;
3. 弹窗打开期间冻结 label 重求值(门控);
4. 若定系 macOS 26 MenuBarExtra 系统行为:记录规避 + 上游 radar。

## 验收

- 弹窗开 60s:自身 CPU ≤ 主窗口观看档(~4%),哨兵法复核;
- 关窗回落 ≤3% 不回归;
- `sh scripts/check.sh` 全绿;徽标目验数字/变色行为不变。

**2026-10-28 深夜实验台就绪(待用户回来跑两轮)**:

- 新线索(采样深挖):37% 布局级联的叶子 = `NSHostingView.layout()` 内的
  `ViewGraphRootValueUpdater.render(targetTimestamp:)` 帧钟;label 的
  `MenuBarBadgeRenderer.image → ImageRenderer._nsImage → renderUntilStable`
  真渲染帧在场(24/22 样本),同时弹窗内容(RankingListRow×13/MeterBar×9)
  也在帧驱动下反复求值——两嫌疑并列,静态分析无法定谳。
- 关键反转:**渲染器本就带 LRU 等值缓存**(值不变零开销),票内"候选修法1"
  已存在于码中;故要么值在弹窗开期间高频变化(缓存持续 miss),要么凶手在
  弹窗内容侧。
- 实验台:worktree `feat/popover-badge-fix` 三处 TEMP 改动(渲染 miss 计数
  日志 category=BadgeProbe / defaults 开关 debug.staticMenuBarLabel 静态徽标
  / debug.staticPopover 静态弹窗),Debug build 已就绪
  `.worktrees/popover-badge-fix/build/DerivedData/Build/Products/Debug/Pulse.app`。
- 已跑:哨兵A(真徽标基线)两次共 ~37 分钟,弹窗未开(用户离开);
  **副产品:弹窗关 37 分钟徽标真渲染 = 0 次(迟滞+缓存设计正常)**。
- 复跑协议:起 debug 版(开关全关)→ 用户开弹窗 30s(基线+BadgeProbe 频率)
  → 杀进程换 debug.staticMenuBarLabel=YES 重启 → 再开 30s(静态徽标)→
  两轮 CPU 相减定谳;热不退则再切 staticPopover 一轮。实验后恢复正式版。

**2026-10-29 上午 A/B/C 三轮对照定谳(附 AppKit 探针正交验证)**:

| 轮 | 徽标 | 弹窗内容 | 弹窗开期间 CPU(2s 窗实录) | 结论 |
|---|---|---|---|---|
| A | 真渲染(103 次≈每秒1次,网络槽直通迟滞) | 真 | 高温窗 38% 起 | 基线复现 |
| B | 静态旁路(零渲染,BadgeProbe 0) | 真 | 稳定 45-68% | **徽标无罪** |
| C | 真(30s 档,渲染 0 次) | 静态一行字 | 稳定 38-50% | **弹窗内容无罪** |
| 探针 | NSStatusItem 文本 | NSPopover 静态 SwiftUI 列表 | **0-1% ×60 秒**(标记文件证明确实开窗) | **AppKit 路线清凉** |

- C 轮采样主线程 45% 仍陷 UpdateCycle→CA flush→NSWindow layoutIfNeeded 级联
  (与 A 轮同构)——内容与徽标双静态下系统仍逐帧跑:**macOS 26 MenuBarExtra
  弹窗窗口机制本身逐帧重排**,即 Swift Forums 已报的 MenuBarExtra 行为类。
- 由此:票内候选修法 1-3(等值短路/依赖收窄/门控冻结)**全部被实验证伪**,
  正解 = 候选 4 换轨:NSStatusItem+NSPopover(FluidMenuBarExtra 或照 stats
  手写),探针已验证该路线开窗 0-1%。
- 证据:`round[ABC]_sample.txt.gz` + 各 watch log + `popover_probe.swift`
  均已归档本目录;实验开关与 miss 计数在 worktree feat/popover-badge-fix。
- 待拍板:换轨迁移(中等工程,一次会话级)vs 记档等系统修。

**2026-10-29 迁移首轮合入→回滚记档(教训全收)**:

- 首轮换轨(NSPopover 路线)合入 develop @8071542 后实测三个 bug:
  ①弹窗空白(可见性靠 SwiftUI onAppear 在 NSHostingController 里不触发,
    门控停在透明占位);②需点两次(LSUIElement 首击被激活吞);③点菜单
    连带弹主窗(NSApp.activate 把后台主窗带前台)。
- **"CPU 变多"真相(归因未被推翻)**:activate bug 把主窗带出过一次 →
  退出时开着 → 状态恢复每次拉回 → 主窗后台常开 = 已知 ~10% 观看态
  (wincheck 实证 1280×704 在屏 + 采样见 RankingListRow 渲染);叠加中间
  装过 Debug 未优化版。回滚后复测:0-2% 稳态、零在屏窗,污染源消除。
- 已回滚 develop @7d775e5(手动 build.sh 装回旧版);三修已提交 worktree
  feat/popover-appkit @b647a22(未合,activate 修法待定)。
- **stats 源码研究结论(用户点题)**:stats 不用 NSPopover——PopupWindow =
  NSPanel(styleMask 含 **.nonactivatingPanel**)+ windowDidResignKey 收起 +
  hidesOnDeactivate=false + mouseDown 触发 + viewWillAppear/Disappear 驱动
  可见性 + Tahoe NSStatusBarWindow tiling-constraints 补丁(与本案病灶同族,
  佐证系统级归因)。下一轮照此架构。
- **实验室验证协议(不再消耗用户轮次)**:NSPanel 可程序化开合 → 哨兵+
  采样自查 idle/开窗两态,全绿才回合入。

**2026-10-29 下午 实验室进展(stats NSPanel 架构,worktree feat/popover-appkit)**:

- **已修五 bug(全部程序化自测验证,不再依赖用户轮次)**:
  ①启动即烧 40% → **面板懒创建**治愈(NSVisualEffectView+NSHostingView 常驻
  隐藏面板是空转源;现启动窗 0=1%);②收面板即退 → AppKit
  `_scheduleCheckForTerminateAfterLastWindowClosed` 定时器(法医栈实证)→
  KeepAliveAppDelegate 拒绝关窗即退 + disableAutomaticTermination;③空弹窗 →
  可见性信号 AppKit delegate 直给;④双击 → mouseDown 触发;⑤点菜单弹主窗 →
  NSPanel(.nonactivatingPanel) 天然不激活。
- **两纵火犯真相(修正 C 轮结论)**:MenuBarExtra 机制(静态内容也烧,
  C 轮实锤)+ **内容管线独立纵火**——NSPanel+真实 DashboardView 照样
  ~40%,NSPanel+静态文本 3-4%。utime/stime 拆分:40% 几乎全用户态
  (内核 2-3%)= SwiftUI 渲染管线持续逐帧工作。C 轮"内容无罪"是在
  MenuBarExtra 里测的——机制纵火掩盖了内容纵火。
- **实验室工具链(已可全自动)**:debug.autoOpenPanel(+Offscreen 离屏档,
  面板屏外渲染不挡用户)/ debug.staticPanelContent / debug.staticBadge /
  willTerminate 法医栈。哨兵+sample 全程无人值守。
- **余下唯一问题**:面板开期 DashboardView 1s 档 ~40% 用户态渲染churn
  (嫌疑:MeterBar 0.6s 动画背靠背续帧钟 / 排行行逐秒全量重算 / 图标冷查)。
  下一步:关动画对照 → 1s→2s 档对照 → 定位后最小修,全绿回合入。
- 证据:/tmp/pa_v2_panel_sample.txt、/tmp/pa_off_panel_sample.txt、
  各轮 2s 窗序列已录票;worktree 未合。

## 终局:内容churn 根因定谳 + 修复(2026-10-29)

- **sample 定谳**(/tmp/pa_fix1_baseline.txt,离屏面板开 30s):主线程 busy ~18.5%,
  全部走两条 SwiftUI 逐帧路径——① runloop observer `NSHostingView.beginTransaction
  → GraphHost.flushTransactions → AG::Subgraph::update`(956 点,≈32 次/秒 ≈ 帧频)
  ② `CA::Transaction::flush → NSWindow layoutIfNeeded → NSHostingView.layout →
  ViewGraph render`(1791 点,含 AnimatableFrameAttribute / propagate_dirty /
  FocusBridge 全响应树走查)。utime/stime 拆分与此前一致:几乎全用户态。
- **凶手 = MeterBar 0.6s 宽度缓动被 1s 档读数背靠背重启**(debug.noAnimations
  同机同刻 A/B:开动画 **44.9%/core** vs 关动画 **~10%/core**)。排行卡 ~15 根条
  每秒都有几根跨过 onChange,帧钟永不落。
- **修复 = meter 条显示迟滞**(与徽标 ±2pp 同口径,用户既有拍板模式):
  PulseCore `MeterDisplayHysteresis`(归一占比死区 0.03,锚在已显示值不累积,
  慢漂移不卡死)+ MeterBar onChange 先判死区再挂 Vitals 同款 0.6s 缓动
  (已拍板缓动样式不回退)+ GLOSSARY「显示迟滞」扩句 + 5 例边界测试。
- **复测(离屏 60s,生产代码)**:均值 **4.7%/core**,静置窗 0–2.5%,仅真实
  跳变时短暂起缓动(t+6–10 一窗 34–46 = 系统真负载下的合法动画)。
  优于关动画档——死区连逐秒重排也一并省掉。**面板开期 45% → 4.7% 结案。**
- 门禁:lint/build 绿;hosted 测试唯 EnergyModelSensorTests.liveSmoke 巨刺失败
  (五路合量 1423W,已知 IOReport mJ 巨刺活 bug),单跑 9/9 绿,非本票回归。

## 复燃与终修(2026-10-29 下午,用户报「改了没用,还是稳定 40」)

- **上轮 4.7% 验收失真**:离屏 + 机器闲 + 冷启动头 15–25s 排行未出数(无条可动)。
  在屏真点实测:总览/CPU/内存三页(唯三含 `RankingCardView`)~38%,余 8 页 3–6%;
  悬停与否无差。
- **死区治不了占空比**:所有条在同一 1s 档更新,任一根越线即整树逐帧 0.6s。忙机
  (CPU 40%+/GPU 70%)探针实录 onChange ~40/s、越死区 4–6/s → 帧钟几乎不停。
  同面板运行时开关 A/B:缓动开 36.5% → 关 8.4% → 再开 37.4%。
- **用户拍板删动画**(「根本就体感不到的东西不应该存在」):MeterBar 读数直绘;
  MeterDisplayHysteresis 及其测试随之删除(唯一用途是少起缓动);DESIGN.md 排行卡节
  记档防回退。复测(在屏真点,排行已出数):总览 7.7% / CPU 页 7.7%。
- 顺修两条换轨回归:①tab 栏上方 ~32pt 空白 = 隐形标题栏算安全区 → hosting
  `safeAreaRegions = []`(面板 696→664);②「打开主窗口」无反应 = `.suppressed`
  致主窗内容从未建、开窗桥零捕获(日志实证)→ 改「启动即藏」(首帧前透明 + close,
  门控 onDisappear 归零;实测启动零上屏、按钮开窗上屏、关窗回空闲 0–5%)。
- 残余 ~8%(1s 档整面板重画)高于票面 ~4% 目标,另议。
