# P0.6:UI 对齐 Vitals(视觉跃迁)

Status: done

## Problem Statement

用户看了 Vitals 官网后的直接反馈:"有 CPU/内存分类什么的,还有图表,跟我们现在的应用差很多"。Pulse 目前是全灰的单列组卡列表,没有走势图、没有指标分类、没有占比可视化——信息是对的,但观感是"另一个档次的产品"。

## Solution

按 `docs/ui/vitals-style-reference.md` 的拆解,落地全部 9 项"不需要 P1 历史数据"的差距:内存环形缓冲驱动的 strip 走势图与 avg/peak 统计对、每指标强调色体系、圆体大数字排版、排行 meter 条、指标 tab 化布局、Memory by App 环形卡、简化状态徽章、头部环境信息。P1/P2 项(长历史/告警/Projects tab/GPU)不在本 spec。

## Implementation Decisions

- **内存环形缓冲**:系统负载 + 每组 CPU%/内存的近期窗口(~60 点,随采样轮推进),不落盘;avg/peak/min 在缓冲上折叠。纯逻辑,单测覆盖
- **走势图**:组卡底部 strip 微柱图(参照官网 44 柱形态)与详情面积图,Swift Charts 或 Canvas 由实现者按性能取舍;数据仅内存窗口,无 P1 依赖
- **设计令牌**:每指标强调色浅/深双套(色值以 docs/ui/vitals-style-reference.md §1 为准),渗透到 tab 选中态、meter 轨道、图表、徽章;孤儿橙保留
- **排版**:大数字 SF Pro Rounded(.fontDesign(.rounded))+ tabular 数字,单位小字;三列小统计(avg/peak/N 进程)
- **tab 化**:弹窗顶部图标 tab(总览/CPU/内存 + 更多按需)、主窗口药丸 tab 条;tab 内容以现有实时数据重组,不造空 tab
- 零第三方依赖不变;遵守 ADR-0001/0002/0003 与 GLOSSARY 口径

## Testing Decisions

- 环形缓冲/统计折叠/tab 内容模型:纯逻辑单测(Synthetic 源序列)
- 设计令牌表完备性(每指标浅深双套、互异)单测
- 图表与排版:SwiftUI 预览 + 手动验收(延续 P0 的 UI 测试决策)
- 既有 148 测试保持全绿

## Out of Scope

长历史累计与 30 天图(P1 SQLite)、Worth a Look 告警面板(P1 AlertEngine)、Projects/dev server tab(P1 §8)、GPU/Neural/温度(P2)、音量/蓝牙(有意砍掉)

## Further Notes

- 差距全清单与设计令牌出处:`docs/ui/vitals-style-reference.md`
- 用户拍板:四件套(走势图/强调色/tab/meter)优先,其余 5 项顺手收尾
