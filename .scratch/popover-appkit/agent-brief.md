# 实施子代理通用说明(popover-appkit)

先读:`.scratch/popover-appkit/spec.md`、你负责的票、根目录 `DESIGN.md`(§Typography / §Layout / §Shapes / §Components)、`AGENTS.md`。

## 你在做什么
把菜单栏弹窗里的 SwiftUI 卡片按**紧凑档**(`isCompact == true`)一比一改写成 AppKit。
外观数值(字号、字重、间距、圆角、颜色、定宽列)必须和 SwiftUI 原版一致,原版是唯一参照;
不要"顺手改进"样式。主窗口仍用 SwiftUI 原版,**不要改、不要删**任何 `Pulse/Views/` 下的文件。

## 地基(已在分支上,直接用,先通读)
- `Pulse/Popover/PopoverKit.swift`:`FlippedView`、`Color.ns`(SwiftUI 令牌 → NSColor,保留浅深)、`Ink`(primary/secondary/tertiary)、
  `PFont.text/digits/rounded`、`makeLabel`、`setText`(值未变不写)、`symbolImage`/`makeSymbolView`、`hstack`/`vstack`/`spacer`、`pin`/`fixed`/`fillWidth`、`PassthroughView`。
- `Pulse/Popover/ObservedUpdater.swift`:`ObservingView` —— 卡片继承它,覆写 `update()` 读 observable 模型、写子视图;
  上窗自动开始追踪、离窗停止;只有 `update()` 里读到的属性变化才会重放。**不要用 Timer 轮询数据。**
- `Pulse/Popover/PopoverCardParts.swift`:`CardView`(卡壳,紧凑 12 圆角 + 12 内距)、`ClickableCardView`、`BadgeView`、`makeCardHeader`、
  `CardSubHeaderView`、`StatValueView`、`DotView`、`EmptyStateView`(可带 link 动作)、`LinkButton`、`makeRowValue(minWidth:)`、`FigureView`、`ChipView`、`MeterBarView`。
- `Pulse/Popover/PopoverCharts.swift`:`StripChartNSView`(44 柱)、`AreaTrendChartNSView`(56 点)。
- 范例卡:`Pulse/Popover/PopoverMetricCards.swift`(`MetricMainCardNSView` / `OverviewMetricCardNSView`)。照它的写法。
- 页面装配:`Pulse/Popover/PopoverPages.swift`。你只改自己负责的 tab 的 `case`(把占位换成你的卡);其余不动。

## 性能纪律(这次重写的目的)
- 颜色只在 `draw(_:)`、文本、`contentTintColor` 里用动态 NSColor;**不要**把动态色转 CGColor 塞 layer。
- `update()` 里只写变了的东西(`setText`、比较后再 `needsDisplay`);行列表按需复用行视图,不要每轮全拆全建
  (行数变了才增删)。
- 不加任何动画。悬停效果只在原版有的地方加(NSTrackingArea,`.activeAlways`、`.inVisibleRect`)。悬停提示用 `toolTip`。
- 布局用 NSStackView / Auto Layout;数值列按原版定宽,避免文字变化撑动整卡。

## 交互
原版里的按钮动作原样接上(处置走 `DashboardModel.requestEnd*` / `requestStopAllDevServers`,NSAlert 关口在 `KillRequestFlow`,不要另写确认)。

## 工程纪律
- 新文件放 `Pulse/Popover/`,文件名以 `Popover` 开头;加文件后 `xcodegen generate`,绝不手改 pbxproj。
- 构建:`xcodegen generate && xcodebuild -project Pulse.xcodeproj -scheme Pulse -configuration Debug -derivedDataPath build/dd -clonedSourcePackagesDirPath ~/Library/Caches/pulse-swiftpm build 2>&1 | grep -E "error:|BUILD"`。
- lint:`sh scripts/lint.sh --fix` 后再 `sh scripts/lint.sh` 必须无 error。
- **不要启动 Pulse、不要合成鼠标点击 / 截屏**(多个代理共用一台机器和一个菜单栏;视觉验收由主会话统一做)。
- 只在你的 worktree 里工作;完成后在你的分支上提交(`feat(popover-appkit/NN): ...`),**不要合并、不要推送**。
  提交会跑 pre-commit(lint + 构建),可能要几分钟。
- 代码注释用中文,风格照现有文件;引用工单写全名 `popover-appkit/NN`。

## 交回
最后回复:做了哪些卡、每张卡和原版有没有任何已知差异(没有就写没有)、拿不准的地方。不要贴代码。
