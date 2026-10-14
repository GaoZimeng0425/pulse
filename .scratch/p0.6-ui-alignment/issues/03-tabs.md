# 03: 指标 tab 化布局

**What to build:** 弹窗与主窗口从单列列表升级为指标 tab 结构:弹窗顶部图标 tab(总览 / CPU / 内存,后续指标随 P1 增加)、主窗口药丸文字 tab 条(同三 tab,形态参照 Vitals);选中态用指标强调色(tint 派生)。tab 内容以现有实时数据重组:总览 = 现组卡列表 + 系统负载卡;CPU = 按 CPU 视角的组排行 + 头部负载;内存 = Memory by App 环形卡(Swift Charts SectorMark,top5 + 其他)+ 内存组排行。不造空 tab、不做无数据的指标。

**Blocked by:** 01(走势图进组卡)、02(强调色令牌)。

**Status:** ready-for-agent

- [ ] 弹窗图标 tab 与主窗口药丸 tab:总览/CPU/内存三 tab,键盘 ←/→ 可切
- [ ] 选中态用指标强调色;tab 结构纯逻辑可测(内容模型)
- [ ] Memory by App 环形卡:top5 + 其他分段,图例带应用图标,环心大数字
- [ ] 各 tab 无数据/空组降级正常
- [ ] 既有测试保持全绿 + tab 内容模型单测
- [ ] 中文文案

## Comments
