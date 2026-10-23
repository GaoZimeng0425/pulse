# 01: 架构审计修复——GATT 泄漏 / 双档竞态 / 走势污染 / SoC 派生错值 / 尾部五件

**What to build:** 2026-10-23 四路 subagent 审计(核心模型/Live 适配器/功能装配/历史管线)核验后的修复批次:① GATT 探针一次性+泄漏常扫管理器 ② 双档驱动打破单 actor 串行前提(Energy/Smc 无锁竞态)③ CoreAudio 回调内换挂监听死锁风险 ④ GPU/ANE 走势环被 stale 灌满 + SoC 派生组别错位(错值已进历史)⑤ 尾部:功率通道中途新增巨刺 / 容器负 ΔCPU 与内存折叠 0 / 历史冻结仪表 / 功率合计 NULL 传染。

**Status:** done

- [x] ① GATT 探针 start() 重置 finished/attempted(第二轮不再 no-op,不再泄漏永扫的 central)
- [x] ② Energy/Smc provider stateLock 串行化双档(锁段拆同步方法,NSLock 禁 async 上下文);Smc previous 仅成功时更新
- [x] ③ 声音监听器增删移专用串行队列(HAL 回调只投递请求);teardown tornDown 标记挡在途重挂
- [x] ④ 六 P2 feature 换 markedDriver + fresh-only apply(stale 不灌走势环/不打脏观察);SoC 派生改读 .soc 新组
- [x] ⑤ 功率中途新增通道该域本轮跳过;容器负差钳 0 + 内存 nil 透传;历史仪表 90s 过期出空段;功率合计 COALESCE+FILTER
- [x] 顺带:命名表 51 条大写 V*/I*/P* 条目归正 voltage/current/power 类型(惰性雷,温度门放宽前必须拆);SMC 温度候选门放宽("T 前缀 ∨ 表标温");FNum 钳 0…8;文案三处(功率 caption/历史空态/事件注释)
- [x] check.sh 全绿 741 例(核心 400 + app 341;新增 6 例回归测试)

## Comments

**执行记录(2026-10-23)**:审计五项全部修复,每项带回归测试(功率中途通道/SoC 组别/容器负差/仪表过期/功率 COALESCE/GPU stale 走势)。**SoC 修复比审计发现的更深**:命名表归组之外,builder 的 T 前缀单一闸把 SOC MTR/PMGR SOC Die 整个挡在温度面外——门放宽后 V*/I*/P* 误标条目变活雷,51 条归正一并拆掉。arm64-only 目标机上这些 Intel 键不在场,零回归面。

**已知残留(不修,记档)**:ContainerSensor 阻塞 socket 在协作线程(≤5s 超时,挪全局队列属架构活);BluetoothModel.merge 的 poweredOn 硬编码 nil + 无名行 id 可撞(API 打磨);MonitorFeatures registry 双份手工维护无防漂移测试;GATT 探针生命周期无单测(需真蓝牙栈,以代码评审钉住)。

**待用户目验**:传感器页 SoC 派生行有真值(SOC MTR 在场时);GPU 页走势环关窗重开后不再出现假平线段。
