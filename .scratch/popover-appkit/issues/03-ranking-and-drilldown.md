# 03 组排行卡 + 进程下钻 + 模块排行卡

Status: done(2026-10-30,feat/popover-appkit)
Blocked by: 01

## 做什么
- 「当前最忙」组排行卡紧凑档:表头、行(图标 18 / 名称 12.5 / 副文 / meter 52 / 定宽数值列 / 行尾 30pt 列)、
  组 CPU > 100% 数值圈红、悬停出结束按钮(toolTip)、点行展开、展开后进程下钻(选中进程详情 + 结束进程)。
  处置走 `model.requestEndGroup` / `requestEndProcess`(NSAlert 关口不变)。
- 模块排行卡(能耗影响 / AI 助手 / 读写最多 / 每进程流量):同一行组件、只读、注脚、空态。
- 行复用:采样轮刷新只改内容不重建行视图。

## 参照
RankingCard.swift、RankingList.swift、ProcessDrilldownView.swift、ModuleRankingCard.swift、MeterBar.swift。
