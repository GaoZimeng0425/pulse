# 02: SensorProvider 骨架 + 电池卡(曳光弹)

**What to build:** 新传感器架构立起来,并用最简单的传感器打穿全程(ADR-0004):薄 SensorProvider 协议(cadence: heartbeat/every(seconds:)/onEvent + snapshot + lastGood)+ 单一调度器 actor;电池卡作为第一个真 provider——IOPS 通知事件驱动(不轮询),电池页进入弹窗与主窗口的 tab 体系:电量、充电状态、剩余时间、健康度、循环次数、功率(电流×电压)。「接着电但不充」显示为"优化充电已介入";没电池的机器整页隐藏。

**Blocked by:** None (can start immediately)(电池不依赖探针)

**Status:** ready-for-agent

- [x] SensorProvider 协议 + 调度器 actor 落地;心跳型指标仍在 Sampler 循环,现有测试全绿
- [x] 电池页在弹窗与主窗口 tab 体系出现,六项读数真实显示
- [x] 健康度回退链 + NotChargingReason 映射 + 设计容量为 0 钳 1 的除零防护,合成夹具单测
- [x] 读失败显示上次好值(lastGood),不白屏不崩溃
- [x] 无电池机器整页隐藏(真机或夹具验证)
- [x] 事件驱动挂接冒烟验证(电源状态变化触发读取)
