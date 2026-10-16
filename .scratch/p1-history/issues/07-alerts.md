# 07: 告警引擎 + 系统通知

**What to build:** 告警规则生效:纯规则引擎(匹配器 × 指标 × 阈值 × 持续时长 × 冷却期;进入需连续 3 次超阈,退出需连续 6 次低于阈值−20%——迟滞防抖);四条预设上线(系统负载 >70% 持续 5min / 组 CPU >300% 持续 10min / 新组内存 >2GB / 磁盘可用 <20GB;第五条 dev server 闲置随工单 08 接入);设置新增「告警」页逐条开关、阈值可改;通知走系统通知中心——授权在首次开启规则时才请求,拒绝则降级应用内提示;点开通知经现有窗口导航直达对应视图。

**Blocked by:** 05(磁盘剩余规则需要磁盘读数)

**Status:** done (2026-10-16;真机点击走查随工单 12 验收)

- [x] 规则状态机注入时钟单测:进入/退出/冷却/迟滞全路径(AlertEngineTests 13 例:持续时长满足才发/连续 3 次进入/带内两不靠/连续 6 次安全侧退出/冷却期抑制与期满重发/逐组独立 streak/组消失自动解除/新组出生窗/设置变更重置)
- [x] 四条预设默认值与 spec 一致(70%/300%/2GB/20GB + 持续 5min/10min,预设值单测钉死);设置页开关+阈值修改即时生效并持久(UserDefaults JSON,store 6 例;第五条 dev server 闲置仅规则位,数据源随工单 08)
- [x] 通知授权时序正确(首开才请求,标记跨启动持久只请求一次);拒绝后规则仍判定、仅应用内提示(AlertCenterTests 假 sender 钉死;系统弹窗本身属真机走查)
- [x] 点通知直达对应视图——代码接线完成:kind→AlertRoute 纯映射单测钉死(系统负载→总览、组 CPU→CPU 页、磁盘→磁盘页、新组内存→内存页),delegate 点开→激活 app→记落点→广播开窗→主窗口消费落 tab;**真机点击验证随工单 12 验收走查**(锚点③一并覆盖)
- [x] 发送层为薄封装冒烟测试(文案拼装/路由解析纯逻辑 + 授权只读查询冒烟);规则引擎全纯逻辑(值类型,注入时钟,零 UI 依赖)

## 实现记录(2026-10-16)

- **引擎(Pulse/AlertEngine.swift,纯逻辑)**:五元组落地为「匹配(喂食种类+主体)× 阈值 × 持续时长 × 冷却期」+ 方向(above/below);进入 = 连续 3 次越阈且跨越 sustain(无时长要求的规则仅看次数),退出 = 连续 6 次安全侧(阈值∓20%,迟滞带内两不靠——两侧计数都清零);冷却期锚定"上次实际发出",冷却期内重满足不重发、期满当轮即发(持续多时的越阈每过一个冷却期再提醒一次)。逐主体(组)独立状态;组消失即解除(firing→resolved),重生 incarnation 从头计数。
- **新组内存语义(实现拍板)**:"新组" = 上一轮不在场、本轮在场的 incarnation(SampleHistoryStore 逐出语义同源);出生窗 = 该 incarnation 前 3 个观察(= 进入次数,出生即超阈且稳住三轮才触发),窗外的内存增长是正常使用不告警;app 启动首轮只立基线,已在跑的组不算新组(首读置零惯例)。
- **设置(AlertSettingsStore)**:UserDefaults JSON 存 {开关, 阈值}(键 alertRuleConfigs);持续/冷却/方向随种类预设定型不可改;设置变更由引擎按策略表变化检测——立即解除在发告警并清计数(冷却锚点与新组序龄保留),即"阈值可改、即时生效"。
- **通知(AlertNotification.swift)**:发送缝三件事直通 UNUserNotificationCenter(授权请求/状态查询/发送);identifier = 种类|主体(重发替换不堆叠);userInfo 带路由。授权时序:首开任一规则(0→1 迁移)才请求,标记持久(alertAuthorizationRequestedKey)只此一次;拒绝 → authorizationDenied 置位,规则照常判定,应用内横幅(AlertBannerView,主窗口 + 弹窗共用)即降级出口。
- **路由**:点开通知 → delegate 解析路由 → NSApp.activate(LSUIElement .accessory 下先激活再开窗,弹窗按钮同序沉淀)→ 记 pendingTab → 广播;MenuBarExtra 常驻标签视图持 openWindow 响应广播开窗,主窗口 onAppear/onReceive 消费落点切 tab。popover 无法程序化打开,深链一律落主窗口(spec 既定)。
- **喂食(SystemMonitor)**:每轮采样(系统负载 + 全部组聚合口径)与磁盘容量读数(Finder「可用」口径,读不到不喂)进 AlertCenter;引擎零新调度,挂在既有采样交付节奏上。
- **单测纪律**:全合成序列 + 注入时钟/假 sender,零真实负载、零真实等待(真负载触发验证属工单 12 锚点③);新增 AlertEngineTests 13 + AlertSettingsStoreTests 6 + AlertCenterTests 6 + AlertNotificationSmokeTests 4,全量 382 例绿。
