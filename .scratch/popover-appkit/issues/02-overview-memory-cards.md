# 02 总览小卡 + 内存双环 + dev server 卡

Status: done(2026-10-30,feat/popover-appkit)
Blocked by: 01

## 做什么
- 总览页:6 张紧凑指标卡(两列、间距 8;电池随 hasBattery),点卡跳对应页签,
  卡内容 = 副卡头 / 22pt 大数字 + 注记 / 36pt 44 柱走势(`MetricCardView.compactBody` 同数值)。
- 内存构成环(by Type)与按 App 环(`RingCardView.memoryByType` / `memoryByApp` 紧凑档):
  自绘扇区代替 Swift Charts,扇区几何 / 图例 / 环心数字(16pt)与旧版一致。
- dev server 卡(紧凑档)+「全部停止」走 `model.requestStopAllDevServers`。
- 组装总览页与内存页(主卡在 04、排行在 03,先接)。

## 参照
OverviewCards.swift、RingCardView.swift、DevServerViews.swift、MetricTabStack.swift `.overview` / `.memory`。
