# 02: 容器读取挪出协作线程——阻塞 socket 的执行域归位

**What to build:** 2026-10-23 审计残留(01 票记档):`LiveContainerSource.read()` 的 socket 三件(connect/recv 至 5s 超时上限)跑在 Swift 协作线程池上——引擎卡死时一个协作线程被堵满 5s,恰好与其它 async 工作(传感器 tick、历史落库)争同一池子。修法:阻塞段包 `withCheckedThrowingContinuation`/`withCheckedContinuation` 挪 `DispatchQueue.global().async` 执行域;stats 的并行单发 task group 形状保留(每容器一发不变);Swift 6 Sendable 边界照 EnergyModelSensor 的锁纪律收口。注意:这不是正确性 bug(超时有界、仅容器页可见时发生),是调度卫生——所以从 01 修复批次里切出来单独立项。

**Blocked by:** None

**Status:** needs-triage

- [ ] recv/connect 阻塞段全部在全局队列执行域,协作线程零阻塞(采样栈佐证:容器页可见时主线程/协作池无 5s 停顿)
- [ ] 并行单发与超时语义不变(5s 接收超时、8MiB 上限、socket 缺席安静空态)
- [ ] check.sh 全绿;关两窗指纹全零
