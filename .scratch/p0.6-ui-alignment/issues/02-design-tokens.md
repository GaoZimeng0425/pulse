# 02: 设计令牌 + 圆体大数字 + meter 条

**What to build:** Pulse 的视觉语言从"全灰"升级为"每指标一色":按 docs/ui/vitals-style-reference.md §1 的色值建浅/深双套指标强调色(CPU/Memory/Disk/Network 等),渗透到组卡图标、排行 meter 条、tab 选中态预留;组卡大数字改 SF Pro Rounded + tabular,单位与副统计小字分层;组卡与进程行加 6px 占比 meter 条(按当前榜单榜首归一)。孤儿橙保留原语义。

**Blocked by:** 无(可立即开工;与 01 并行)。

**Status:** done

- [x] 指标强调色令牌表:浅/深双套,色值取自参考文档,单测断言完备互异
- [x] 组卡大数字:圆体 + tabular,单位/副统计小字分层(视觉参照参考文档 §1 排版)
- [x] 组卡与主窗口进程行:占比 meter 条(榜首归一,强调色填充)
- [x] 类别样式表(cardStyle)接入强调色,孤儿橙不变
- [x] 既有 148 测试保持全绿,令牌表新增单测
- [x] 中文文案不变;深浅模式切换正常

## Comments
