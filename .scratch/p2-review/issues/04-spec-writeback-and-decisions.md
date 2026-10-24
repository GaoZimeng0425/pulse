# 04: Spec 回写 + 待拍板(弹窗温度组 / 三项缺失功能)

**What to build:** 2026-10-24 P2 收尾审查 Spec 轴(`p2-review/REPORT.md`)。代码已按后来的拍板走、
`.scratch/p2-sensors/spec.md` 没回写的五处回写;另有一处代码违背 spec 原文、三项 spec 要求未实现,
需要用户逐项拍板"改代码"还是"改 spec"。

**Blocked by:** None

**Status:** ready-for-agent(拍板项 A–D 已全部定,2026-10-24;剩余为 spec 文本回写)

## 待拍板

- [x] **A. 弹窗温度组带明细卡**:Story 17「弹窗温度组只放派生值(Average/Hottest/最快风扇)」;
  代码按 2026-10-20「每个 tab 两处一致」拍板(`Pulse/Views/MetricTabStack.swift:4`),弹窗温度组带了
  明细卡(:58 一带)。→ **用户拍板(2026-10-24):改代码,弹窗只留派生值**——传感器 tab 是"两处一致"
  的明文例外;实施见 `p2-review/08`。
- [x] **B. 派生值"最快风扇"**:`SmcDerivedTemps`(`SmcModel.swift:116-123`)只有六个温度字段。
  → **用户拍板(2026-10-24):跟 A 走 = 做**(弹窗温度组靠它承载风扇信息);实施见 `p2-review/08`。
- [x] **C. 风扇最小转速**:Story 7「当前/最小/最大以进度条展示」;`minRpm` 已解析但视图未用,进度条
  按 rpm/max(`SmcCardViews.swift:88,109`)。→ **用户拍板(2026-10-24):做**——进度条改
  (rpm−min)/(max−min) 并标出上下限;实施见 `p2-review/08`。
- [x] **D. 历史页分项**:Story 8 温度派生值与五路功率进 30 天历史;库里已存 CPU 均值 + 全机最热、
  五路分列,历史页只能看 CPU 均值与五路合计。→ **用户拍板(2026-10-24):做**,立 `p2-review/07`;
  spec Story 8 保持原文不收窄。

## 直接回写(无需拍板,代码即现状)

- [ ] Story 12 + spec 第 59、71 行:蓝牙改"默认关;设置开关/卡片按钮是唯一触发源;采集闸 = 可见 ∧
  已开启 ∧ 已授权"(acbfdbf;`BluetoothFeature.swift:150-152`),引用 `CODING_STANDARDS.md` 权限/TCC 节。
- [ ] Story 21 + 第 55 行:原文「<10 或 >120 沿用旧值、0 或 >110 丢弃」自相矛盾(>120 ⊂ >110);
  按代码与 p2-sensors/04 口径改为「≤0 或 >110 丢弃;(0,10) 沿用旧值」(`SmcModel.swift:222-229`)。
- [ ] Story 16 + 第 67 行:弹窗组形态改按"每个 tab 两处一致"描述,**传感器 tab 例外**(弹窗只放派生值
  含最快风扇,Story 17 原文保留);GPU 组为三张卡;容器组取前 6 台(全部状态,运行中置顶——随
  `p2-review/03` ④)。
- [ ] Story 23 + 第 65 行:窗口最小宽仍 720(`MainWindowView.swift:117`),11 tab 靠 `.selectedOnly`
  (未选中只显示图标)装下——改写为此方案。
- [ ] 第 59 行"睡眠停扫/唤醒重启":按 p2-sensors/06 记档口径——靠进程随睡眠挂起自然停止,无专门实现。

## Comments
