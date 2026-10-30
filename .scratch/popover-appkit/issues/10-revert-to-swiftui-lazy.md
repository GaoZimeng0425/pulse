# 10 回退 AppKit 重写,SwiftUI 弹窗改惰性栈

Status: done(2026-10-30)

## 为什么回退

AppKit 重写(01–09,develop befc619)合入后,对照实验推翻了立项依据:

- 立项时的 AppKit 探针只有 15 行排行,真实面板上百行——行数没对齐,把「行全建」的成本误判为
  「SwiftUI 本身」的成本。
- 旧 SwiftUI 版只把滚动区与排行卡行容器两处 `VStack` 换成 `LazyVStack`(2 行),背靠背三轮:
  鼠标移动 7.0–7.1% / 滚动 25.3–25.8% / 静止 5.1–5.2%,与 AppKit 版(7.4 / 25.8 / 5.0)持平。
- 再往下的天花板(独立探针,120 行每秒全量更新,同宿主):SwiftUI List 滚动 ~10%、LazyVStack 12–14%、
  AppKit NSTableView ~5%(原生一档)。SwiftUI 最好约为原生 2 倍。
- 用户拍板 B(2026-10-30):回到一套 SwiftUI 代码,接受约 2 倍开销,换维护成本。

## 做了什么

- `git revert -m 1 befc619`(AppKit 弹窗、ObservedUpdater 及测试、文档改动一并撤回;本目录票据保留作历史)。
- `DashboardView` 滚动区与 `RankingListCard` 行容器改 `LazyVStack`;DESIGN.md 排行列表条补「不得退回 VStack」。

## 余项(未做)

- 滚动 ~25%:可试改 `List`(探针 ~10%,真实面板因上方卡片预计 15–20%),需另开票评估。
