# 09 切换收尾 + 实测验收

Status: ready-for-agent
Blocked by: 02, 03, 04, 05, 06, 07, 08

## 做什么
- 删弹窗专属 SwiftUI(DashboardView / MenuBarPopoverGate / 仅弹窗用的组件),主窗口共用者保留;
  `debug.staticPanelContent` 等弹窗实验开关一并清理。DESIGN.md / GLOSSARY 相关描述改为 AppKit 出处。
- 逐页截图对照旧版;spec 交互清单逐项走查。
- CPU 三态实测(流程:重启 → 等 40s → 开面板 → 面板内 60Hz 晃鼠标 12s → 滚动 10s → 静止 10s,
  `top -l N -s 1 -pid`;测前确认屏幕未锁、显示器亮,截图确认面板在渲染),内建屏 + 外接屏各一轮,
  结果写回本票。
