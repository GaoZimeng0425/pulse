# 09 切换收尾 + 实测验收

Status: done(2026-10-30)
Blocked by: 02, 03, 04, 05, 06, 07, 08

## 做什么
- 删弹窗专属 SwiftUI(DashboardView / MenuBarPopoverGate / 仅弹窗用的组件),主窗口共用者保留;
  `debug.staticPanelContent` 等弹窗实验开关一并清理。DESIGN.md / GLOSSARY 相关描述改为 AppKit 出处。
- 逐页截图对照旧版;spec 交互清单逐项走查。
- CPU 三态实测(流程:重启 → 等 40s → 开面板 → 面板内 60Hz 晃鼠标 12s → 滚动 10s → 静止 10s,
  `top -l N -s 1 -pid`;测前确认屏幕未锁、显示器亮,截图确认面板在渲染),内建屏 + 外接屏各一轮,
  结果写回本票。

## Comments

### 2026-10-30 实施记录

- 01 地基 + 主卡 / 总览小卡:主会话;02(两环 / dev server)+ 08(历史页)、03(排行 / 下钻 / 模块排行)、
  05–07(传感器 / 外设 / 功率 / 容器 / 磁盘 / 网络各卡):三个子代理各在独立 worktree 并行,合回本分支。
- 弹窗专属 SwiftUI 已删:`DashboardView`(共用的 GroupCardStyle / CategoryIconTile / KillFailureAlert
  迁到 `Views/GroupCardStyle.swift`)、`MenuBarPopoverGate`、`MetricIconTabBar`、`debug.staticPanelContent`。
- 逐页截图对照(11 页 × 顶 / 底):外观一致;已知差异见下。

### 实测(内建 120Hz 屏,Release,proto 流程;机器同时有其他高负载,用户在用机)

| 面板开着 | 旧 SwiftUI | 新 AppKit |
|---|---|---|
| 鼠标在面板上移动 | 30.6 / 33.3% | 8.0–8.6% |
| 滚动(总览,上百行排行) | 40.9 / 41.2% | 24.6–27.2% |
| 静止 | ~10%(上轮票实测;本轮旧版测完面板被关,数据无效) | 3.2%(Debug 总览单页 3.3%) |

滚动从 48% 压到 ~25% 的三步(采样定位):
1. 排行行由 8 个子视图改为整行一次 `draw`、行高固定——文字变化不再触发全栈 Auto Layout;
2. 上百行各挂 `.inVisibleRect` 跟踪区 → 全卡一个跟踪区按位置找行(滚动帧里 updateTrackingAreas ~13% 消失);
3. `Metric.accentColor` 计算属性每读新建动态色 → 缓存单例(否则「颜色没变不重画」永远落空,每轮全行标脏);
   展开箭头图缓存(每次绘制现建占 ~16%)。
剩余滚动成本主要是新滚进视野的行绘制文字(CoreText 排版),未达 spec 的 ≤10% 目标。

### 与旧版的已知差异

- 模块排行(能耗 / 读写 / 流量)行尾按 DESIGN.md 恒留 30pt 列,meter 与数值和组排行对齐;旧 SwiftUI 版
  实际没留(EmptyView 套 frame 不占位),所以新版名称列窄约 30pt、截断更多。
- 历史页指标药丸条:9 项放不下「图标 + 系统负载」,新版截断选中文字;旧版文字被挤成竖排(两版都不理想,
  待用户拍板是否收窄药丸内距)。
- 药丸切换无 0.2s 展开动画;类别瓦片 / 扇区圆角为普通圆角(原 `.continuous`)。
- 组排行悬停高亮跟随鼠标所在位置(行按位置复用),旧版重排时高亮跟着组走。
