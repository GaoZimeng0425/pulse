# 10: 扫描性能——petal 式并行遍历(全卷 6–10 分钟 → ~1.5 分钟)

**What happened:** 用户实测全卷扫描 10 分钟只到 144 GB,质疑回归。诊断(2026-11-02):
不是回归——**探针 15 的「全卷 ≈340 万项 ≈155s」是 Data 卷外推**,`/` 起点的真实全卷
去重后 ~500 万项、单线程 234s(真引擎实测 22,437 项/s,与探针 15 的 21k 完全吻合);
用户遇到 10 分钟是冷缓存 + 系统更新预置 I/O 叠加。参考对照:petal = 子目录级并行
(rayon);purge-app = FileManager 枚举白名单目录 + 受限并发 du,从不全卷走;
dust = rayon 并行。没有人单线程全卷。05 加的 ATTR_CMN_MODTIME 实测仅 -6%,洗清。

**What to build(用户拍板 B:加速扫描;范围收窄另议):** 引擎遍历内核改长驻 worker 池
+ 共享目录栈(petal 式),语义与串行逐位等价。

**Status:** done(2026-11-02,develop@本合并)

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
- **范围收窄(方案 A)未做**:Data 卷单扫 + 密封卷卷级字节注入可再砍一半扫描量并
  消灭克隆重复计水分(982GB 假账系裸 allocated 口径,引擎 PRIVATESIZE 口径无此问题);
  用户拍板先做 B,A 待需要时再议。真机全卷账:去重后 ~500 万项 / 271GB 已见占用。
- **欠目验**:重扫一次全卷,观感 ~1.5 分钟完成、进度条平滑、清单与地图数字与之前同口径。
