# 03: ANE 卡 + 五路功率区——Energy Model 订阅一鱼五吃

**What to build:** IOReport "Energy Model" 订阅打穿:Live 适配器按 **macOS 26 新形状**(响应字典内取通道数组,探针④实证)采样,核心包纯值模型做逐通道单位换算(mJ/nJ/µJ/pJ→J,按单位标签)、能量差分(首读返回 0、Δt 用实测时差、唤醒丢首轮)、按名过滤;GPU 页加 ANE 卡(瞬时功率 W + 按芯片最大功耗表 M4 行归一化 %)与五路功率区(CPU/GPU/ANE/RAM/SoC 各自瓦数与占比),弹窗 GPU 组扩展功率一行。与 GPU 同档同门控(可见 5s)。读失败静默降级空白卡不崩。

**Blocked by:** 02(GPU 页与 toolbar 容量在场)

**Status:** done

- [x] ANE 卡显示真实功率:空载近 0 实测(冒烟 <100W 量级断言);跑本地模型抬升 = 用户目验项(见 Comments)
- [x] 五路功率区五路齐全(CPU/GPU/ANE/RAM/SoC 行 + 榜首归一 meter + 合计;方向互证 = 用户目验)
- [x] PowerModelTests 9 例:单位 10⁶ 数量级/域映射主备求和/首读 0/断档丢首轮(60min 睡眠场景)/负差钳 0/混合单位(mJ+nJ 共存)
- [x] 断档丢首轮由差分器单测钉死(间隔>50s 重置基线);真合盖目验 = 用户项(见 Comments)
- [x] 关两窗指纹全零(实测 PID 88415,含 PowerDomainsCardView/PowerFeature 新名);check.sh 678 例全绿(核心 358+app 320)

## Comments

**2026-10-22 执行完毕(develop @6515272,hook Release 装机+指纹全零实测):**

- 实现:PulseCore PowerModel(五域通道映射按探针④实证通道名:CPU Energy/GPU(备 GPU Energy nJ)/ANE/DRAM(备 DCS)/SOC_REST+SOC_AON 求和;单位表 mJ–pJ stats 同款含未知按 nJ;PowerAccumulator 差分器;ANE 归一化表 M4=6W 未知兜底 8W)+ LiveEnergyModelSource(IOReport 手工 silgen,响应字典可变副本整传订阅——stats 的 macOS 26 兼容路径,采样逐通道取名/单位/整数)+ EnergyModelSensorProvider(5s,与 GPU 同门控)+ PowerFeature + GPU 页 pair{ANE 主卡,五路功率区};project.yml 显式链 -lIOReport(无 SDK 头)。
- 设计拍板:ANE 卡与 SoC 行无独立令牌——ANE 沿用 GPU 页强调色、SoC 三级墨(Neural 与 Memory 同色问题留独立 tab 时再议);差分唤醒丢首轮用"间隔>50s 重置基线"实现(睡眠/门控长停都覆盖,无需唤醒管线)。
- 过程坑:Swift 6 不许 CFTypeRef 直接 as? CFDictionary(silgen 返回类型直接声明成 CFDictionary);CF 层无 mutableCopy 用 CFDictionaryCreateMutableCopy;链接要显式 -lIOReport。
- **待用户目验**:①跑本地模型(ollama/MLX)时 ANE 卡与五路区 GPU/ANE 行抬升;②GPU 页 pair 双卡布局与弹窗紧凑形态;③合盖一夜回来无假尖峰(差分器单测已钉,真机再眼验一次)。
