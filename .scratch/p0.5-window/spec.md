# P0.5:最小主窗口(全部组视图 + 双入口)

Status: ready-for-agent

## Problem Statement

P0 只有菜单栏弹窗(Top-5 截断 + 480pt 高度上限),没有 Vitals 那样的主窗口。想看全部组、想舒服地读长 argv、想在更大的空间里下钻时,弹窗装不下。

## Solution

加一个正经主窗口:展示**全部组**(非 Top-5),组→进程→详情三层结构与弹窗同源(SystemMonitor @Observable 数据);弹窗保留为速览不变。窗口有两个入口:弹窗头部"在窗口中打开"按钮,以及一个新的紧凑菜单栏项(原生下拉菜单:打开主窗口 / 设置… / 退出 Pulse——顺带补上体面的退出方式)。完整 Vitals 式多指标 tab + 历史曲线仍属 P1。

## Implementation Decisions

- Window scene + `openWindow`;`LSUIElement` 不变(无 Dock 图标,窗口从菜单栏体系打开)
- 复用既有视图/模型:组卡、进程下钻、SystemMonitor 状态;窗口版放宽 Top-5 截断与 480pt 高度约束,进程表可排序(CPU/内存)
- 新增第二个 MenuBarExtra(`.menu` 样式,紧凑图标):打开主窗口 / 设置… / 退出;原有 CPU 数字弹窗项保持不动
- 窗口关闭即隐藏(数据管线不受影响,采样不因窗口开关改变节奏——窗口不属于"弹窗打开"状态)
- 中文文案;零第三方依赖;遵守 ADR-0001/0002/0003

## Testing Decisions

- 全部组列表模型、搜索/排序逻辑纯逻辑单测(Synthetic 源);窗口 UI 手动验收
- 既有 140 个测试保持全绿

## Out of Scope

- 多指标 tab、历史曲线、sparkline(P1);窗口内 kill(弹窗已有,窗口版下钻复用同一动作则顺手,不强制)

## Further Notes

- 用户拍板:两个入口都要,菜单栏弹窗保留
- P0 收官状态见 `.scratch/p0/`(9 票全 done);评审遗留缓项记录在 09 号票备注
