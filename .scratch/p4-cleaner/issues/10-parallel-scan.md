# 10: 扫描性能——petal 式并行遍历(全卷 6–10 分钟 → ~1.5 分钟)

**What happened:** 用户实测全卷扫描 10 分钟只到 144 GB,质疑回归。诊断(2026-11-02):
不是回归——**探针 15 的「全卷 ≈340 万项 ≈155s」是 Data 卷外推**,`/` 起点的真实全卷
去重后 ~500 万项、单线程 234s(真引擎实测 22,437 项/s,与探针 15 的 21k 完全吻合);
用户遇到 10 分钟是冷缓存 + 系统更新预置 I/O 叠加。参考对照:petal = 子目录级并行
(rayon);purge-app = FileManager 枚举白名单目录 + 受限并发 du,从不全卷走;
dust = rayon 并行。没有人单线程全卷。05 加的 ATTR_CMN_MODTIME 实测仅 -6%,洗清。

**What to build(用户拍板 B:加速扫描;范围收窄另议):** 引擎遍历内核改长驻 worker 池
+ 共享目录栈(petal 式),语义与串行逐位等价。

**Status:** done(2026-11-02,A+B 均落地:并行 eff658c + Data 根收窄 7134aa6)

- [x] 并行 worker 池(maxConcurrency=1 默认 = 旧递归 DFS 逐位一致,现有测试零改动)
- [x] 每目录先占坑再枚举(firmlink/双挂载去重语义不变);文件硬链接去重 32 分片锁
- [x] 树按「每目录记账 + 收工自底向上拼装」,并行/串行同形树;取消缺口祖先标 partial
- [x] 串行↔并行等价测试(聚合逐字段 + 树逐路径)、并行取消、并行去重语义
- [x] 真机 A/B:串行 233.9s ↔ 并行 6 worker 85.9s(同会话 2.7×;冷串行 352s ↔ 4.1×)

## Comments

- **实现**:`SpaceScanOptions.maxConcurrency`(默认 1);`ScanCore`(worker 池 + NSLock
  同步帮手——Swift 6 async 上下文禁直接 lock,拆同步方法);统计/台账按目录批合并;
  进度按目录粒度跨越 ~2048 项一发。生产 `CleanerModel.productionScanConcurrency = 6`
  (元数据密集型,留核给 UI;引擎侧按活动核数封顶)。
- **基准工具**:/tmp/engine-bench(真引擎+Live 枚举器编译的 CLI,已随会话存档路径);
  /tmp/attr-bench(裸 getattrlistbulk A/B,含 MODTIME/QoS 洗清数据)。
- **范围收窄(方案 A)已落地(2026-11-02 晚,develop@7134aa6)**:用户拍板 A+B 都做。
  生产扫描根 = /System/Volumes/Data(路径天然规范,07 的 firmlink 提升不再触发);
  SSV/Preboot/VM/Update/Recovery 只读卷不再逐文件走,statfs 卷级字节经
  LiveCleanVolumeSummaries(同物理盘 apfs,外置盘不计)注入地图「系统(密封)」单块。
  真机(6 worker):Data 55.9s(93,656 项/s)vs 全卷 86s vs 旧串行 234s——A+B 合计 4.2×,
  对冷缓存 10 分钟场景约 10×。旧全卷账(去重 ~500 万项 / 271GB)留档对照。
- **欠目验**:重扫一次(现在 ~1 分钟完成、进度条平滑);地图出现灰「系统(密封)」块
  (卷级口径,点击有解释);清单数字与之前同口径(都在 Data 卷上)。
