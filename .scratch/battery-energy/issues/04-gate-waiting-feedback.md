# 04: 电池页引导行等待反馈——点开关即时翻转 + 等读数转圈 + 等待期加密轮询

**What to build:** 用户实案(2026-11-23,helper3 修复装机后):「点了去开启
以后没 UI 变化」「是不是没有 loading」——点开关/批准后引导行最长 60s 原地
不动,数据到才突然替换,全程无反馈。三件一起修:
① 动作即时反馈:`PrivilegedHelperStatus.setInstalled` /
`reRegisterAndOpenApproval` 尾部 post `helperStateChanged` 通知,
`EnergyImpactFeature` 监听并立即跑一轮 poll(状态刷新+拉取),引导行
文案即时翻转(去开启 → 等待批准/等待读数);
② 等读数态行尾小号转圈(`BatteryGateHintRow.showsProgress`,
DESIGN.md「小号转圈+文案」同款,`gate == .approvedAwaitingReading` 时),
数据到自动被排行替换;
③ 等待期加密轮询:`pollInterval(fetchFailed:status:)` 纯判定——已登记但
拉取失败(等系统批准/助手未跑起)5s 一档,批准后 5s 内跟上;拉取成功或
未登记(没人等,不空转)回落 60s。

**背景:** 状态机四态文案(energy-gate-fix/energy-one-tap)早已齐备,缺的
只是「用户动作 → 状态翻转」的即时性与等待可视化。批准动作发生在系统设置,
app 侧收不到事件,靠 5s 档轮询的 status 刷新天然覆盖。

**Status:** done(2026-11-23)

- [x] EnergyImpactFeature:通知名 + observerTask(start 挂/stop 撤)+
      pollOnce 返回下一跳间隔(动态)+ pollInterval 纯判定
- [x] PrivilegedHelperStatus:两处动作尾部 post 通知
- [x] BatteryGateHintRow:showsProgress 参数 + 行尾转圈(仅无 action 的
      等读数态);MetricTabStack 构造处传 `gate == .approvedAwaitingReading`
- [x] PulseTests:pollInterval 三态判定 2 例(5s 档/60s 回落,含未登记不空转)
- [x] check 全绿 → 合并装机

**Out of scope:** 设置页开关行的即时刷新(独立 @State 体系,本次痛点在电池
页引导行);「等待读数」detail 文案(首档采集周期未变,「约 1 分钟内」仍准确)。

**夹带修复(与本票零关联,拦路门禁):**
- `AgentIncrementalLiveTests` 夹具时间锚:minutesAgo 最大 800min,每天
  13:20 前跑必越午夜 → 增量账本多出昨天账、金标全量按天切,断言必挂
  (2026-11-23 12:06 实挂;agent-tab/12@48bcce0 带入,此前均在午后跑而
  绿)。修 = 钳到「今天零点+1 分钟」以内,等价性意图不动。
- `SpaceScanEngineTests` / `LiveCoreTickSourceSmokeTests` 各 1 例高负载
  自扰,单跑均绿(既定口径记档合并)。

## Comments

- 落地验证:电池页引导行点「开启并去批准」→ 文案立即翻「等待系统批准」;
  系统设置批准完回 app,≤5s 翻「等待读数」+ 转圈;数据到自动替换成两张
  排行卡,转圈消失。
