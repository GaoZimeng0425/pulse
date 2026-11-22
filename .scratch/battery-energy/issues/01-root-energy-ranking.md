# 01: 电池页能耗重做——root 能耗指数+占比,删 CPU 近似链,空态给开启引导

**What to build:** 用户三反馈一次收(11-22 拍板 B 方案):
①「能耗影响」排行换 **root Energy Impact 口径**:行值 = 占全机百分比(主
数值,meter 同占比归一),副文给指数;注脚「能耗指数 · 60 秒一档 · 活动监视器
同口径」;标题与 AI 卡成对:「耗电排行 · 全部应用 / AI 助手」。
② 特权助手未装/待批准时,两张能耗卡共用**授权型引导空态**(DESIGN.md
CardEmptyState 标准件:一句说明 + 按钮 → 直达设置页开关;待批准态 → 去系统
设置登录项批准;enabled 但暂无数据 → 正常「等待读数」空态)。
③ 删 CPU 近似链:RankingBoard(PulseCore)能耗段、RankingsFeature.energyRows
发布链、电池页 spec 的 CPU 时间用法;底层 5s CPU 差值保留(组排行/告警/历史
共用,不动)。

**背景:** 11-22 用户验收电池页:AI 卡空态无引导违规范(特权助手默认不装,
用户不知何故为空);「CPU 时间」口径看不懂(窗口差值被当累计值误读);页面
三卡三种语言=「丑」的深层原因。用户期望「耗了多少电、占多少百分比」→
root Energy Impact 是可行真值(macOS 不给普通 app 每进程瓦特;苹果自家也用
指数)。AI 卡用户必用 → 助手必装 → 不做双口径保底(B 不 C)。

**Status:** ready-for-agent(2026-11-22 用户拍板「B, 开」)

- [ ] EnergyImpactFeature 增 helper 三态暴露(notRegistered/requiresApproval/
      enabled)+ 占比折算(top ÷ 合计;纯函数,进 PulseCore 配单测)
- [ ] 电池页两卡换口径+标题成对+注脚;ModuleRankingCard 通用卡型不动,
      spec 换数据源与 label
- [ ] 两卡授权型引导空态(按钮路由到设置页特权助手开关;待批准态给
      「去系统设置」深链——TCC 授权用户自点原则)
- [ ] 删 A 链:RankingBoard 能耗段 + energyRows 及其测试同步
- [ ] check 全绿 → 合并装机

**Out of scope:** AI 助手卡行内容(照旧);能耗历史曲线(已走 root 口径);
弹窗 compact 专属形态(跟随主卡自动)。

## Comments

- 落地验证(装机后):设置→通用→开「特权助手」→ 系统登录项批准 → 回电池页,
  1 分钟内「耗电排行 · 全部应用」出数据(AI 助手卡同刻复活);行值是百分比,
  副文指数;没装时两卡是带按钮的引导空态。
