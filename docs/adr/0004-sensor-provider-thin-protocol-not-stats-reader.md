# 传感器以薄 SensorProvider 协议接入,不搬 stats 的 Reader 基类

P1 起传感器分两类脾气:CPU/内存/网络吞吐这类**心跳型**,每 1–5 秒都要新值,否则图是断的;磁盘容量对账、电池、本地快照这类**低频/事件型**,30–60 秒甚至状态变化时才需要读。决定:引入薄 `SensorProvider` 协议(`cadence: .heartbeat / .every(seconds:) / .onEvent` + `snapshot() -> Reading?` + `lastGood` 读失败保留上次好值),由一个轻量调度器 actor 按各自节奏驱动;心跳型指标继续住在 `Sampler` 单一循环节拍里,不拆。把低频活塞进 1s 心跳是用 60 倍频率干 1/60 的活,Sampler 也会膨胀成上帝对象。

参考 stats(MIT)的同构思想——每模块若干 Reader 各自 interval——但不搬它的 `Reader<T>` 基类,理由四点:①DB 写入焊死在基类里(每 Reader 自动写库+节流),而我们的历史是刻意的 rollup 管线(分钟/小时两级+留存清理),采集与存储分开管;②callback 链拖着远程面板与 Widget 两样我们不需要的消费者,本地 UI 由 SystemMonitor 的 @Observable 字段刷新即渲染,不需要回调链;③config.plist 运行时声明模块,违背 ADR-0003 的编译期注册;④每 Reader 自养一个 DispatchSourceTimer,我们用单一调度器 actor 统一驱动,省掉 N 个独立定时器。

本 ADR 即 ADR-0003 预约的"P1 第一个功能模块落地时定义扩展点"之兑现。SensorProvider 及其各原始读数协议(磁盘容量/磁盘吞吐/网络计数/电池/端口扫描/通知发送)都是**编译期测试接缝**——运行期各只有一个真实现、不做运行时替换(ADR-0003 澄清条款同款);缝上全部纯逻辑,延续 P0"整条链只有 ProcessSource 一条缝"的既定哲学。
