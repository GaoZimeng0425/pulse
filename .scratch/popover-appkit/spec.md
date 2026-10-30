# spec:菜单栏弹窗改 AppKit 原生实现(stats 路线)

- 日期:2026-10-30
- 来源:popover-layout-loop/01 删 meter 动画后,面板开期仍 10–30%(静止 ~10–24% /
  鼠标移动 ~27–36% / 滚动 ~31–38%,内建 120Hz 屏)。用户选 D「面板改用 AppKit 原生实现」,
  分期选 **B「11 个页签全部重写完再一次合并」**(2026-10-30 拍板)。

## 依据(可行性探针,2026-10-30 亮屏同位同流程对照)

独立 AppKit 程序复刻总览页最重结构(6 张 44 柱走势卡 + 内存环 + 15 行悬停排行,
每秒全量刷新且打乱排行,同款 NSPanel / `.menu` 毛玻璃 / `.statusBar` 层级):

| 面板开着 | 现 Pulse(SwiftUI) | AppKit 探针 |
|---|---|---|
| 静止 | ~24%(另测 ~10%) | 2.0% |
| 鼠标移动 | 27% | 2.6% |
| 滚动 | 31% | 3.9% |

结论:成本在 SwiftUI(每次 mouseMoved 全树悬停命中检测 5–6ms、滚动逐帧重画、
采样轮全树 diff),不在毛玻璃 / 窗口合成。探针源码:会话 scratchpad `appkit_probe/main.swift`
(一次性,不入库;复测流程见 issues/09)。

## 目标

- 用户点开菜单栏后看到的面板,**外观与交互与现在一致**(DESIGN.md 已拍板样式全保留),
  Pulse 自身 CPU:静止 ≤ 5%、鼠标在面板上移动 ≤ 8%、滚动 ≤ 10%(内建屏)。
- 主窗口、设置窗**不动**(仍 SwiftUI;关着几乎零成本)。

## 范围

弹窗内全部内容:页签栏、页头、滚动区、告警横幅、底排、处置确认 / 失败弹窗,
以及 11 个页签(总览 / CPU / 内存 / GPU / 传感器 / 外设 / 磁盘 / 网络 / 容器 / 电池 / 历史)
的全部卡片。卡片组成与顺序以 `MetricTabStack` 的 `isCompact == true` 分支为准
(含传感器页弹窗只放派生卡的拍板例外)。

## 设计决策

1. **复用呈现模型,只重写排版**:`DashboardModel` / `MetricCardModel` / `MetricTabContent` /
   各 Feature 的 observable 原样复用;AppKit 视图只做「模型 → 画面」。颜色令牌经
   `NSColor(Color)` 桥接(`Color.dynamic` 本就是动态 NSColor,桥接保留浅深自适应)。
2. **刷新机制**:每张卡一个观察回路(`withObservationTracking` 读模型 → 变化后下一拍主线程
   合并重放一次 `update()`),只有读到的属性变化才重画;不用定时器轮询。
3. **布局**:卡内手工 frame 布局 + 卡间竖向 NSStackView;不在每轮刷新里触发整树
   Auto Layout(定宽数值列、文本变化不改卡高)。
4. **悬停**:只给需要悬停效果的行挂 NSTrackingArea(排行行结束按钮 / 行高亮、可点卡);
   提示用 `toolTip`。
5. **SwiftUI 退场**:弹窗专属 SwiftUI(`DashboardView`、`MenuBarPopoverGate`、`MetricIconTabBar`
   等仅弹窗用者)在 09 票删除;与主窗口共用的视图保留。
6. **可见性门控不变**:面板开 = `monitor.setPopoverTab(tab)`,关 = `nil`(采样节奏 1s/5s 与
   传感器按页采集口径不变);关面板时 AppKit 内容树整棵卸下,观察回路随之停止。

## 不做

- 主窗口 / 设置窗迁移;新增功能;样式改动(仍挂账的 `.padding(14)` 等保持原值)。

## 验收

- 11 个页签逐页与旧版截图并排比对,无可见差异(或差异已登记并经用户同意)。
- 交互:页签点击 / ←→ 切换并记忆、总览卡点击跳页、排行行展开 / 下钻 / 结束整组 /
  结束进程(NSAlert 确认,取消为默认)、失败汇总、dev server 全部停止、蓝牙开启 / 授权、
  历史页指标 / 分项 / 范围切换、打开主窗口 / 设置 / 退出、告警横幅。
- CPU 三态达目标(issues/09 流程实测,外接屏与内建屏各一轮)。
- `xcodegen generate` + `sh scripts/check.sh` 全绿。
