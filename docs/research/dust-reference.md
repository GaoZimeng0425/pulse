# dust(bootandy/dust)参考记录:目录树空间扫描的工程护栏

> 2026-10-17 只读调研。输入:浅克隆 `/tmp/dust-ref`(master @ `ae5c770`,2026-09-16)。
> 背景:用户问"dust 查看磁盘的方式和我们的 DiskSensor 一致吗、有什么可借鉴"。结论是
> **两件不同的事,现有监控路径零改动**;本文记录它对"空间扫描"类未来功能
> (spec §8.1 可回收产物扫描、或 Vitals 同款的 per-app 磁盘占用)的护栏级借鉴点。
>
> 协议边界:Apache-2.0(宽松,与 stats/petal 同档),算法/实现可参考移植,
> 文件头注明来源即可。

## 1. 定位:与分析工具不重叠的监控实现

dust 是 `du` 的替代品:从给定路径并行遍历目录树,逐文件取元数据,把大小逐级
向上汇总成"谁最大"的树,终端渲染。它**不做**卷容量、可用空间、purgeable、
快照、IO 计数中的任何一件——不调 statvfs/挂载表(唯一例外见 §2.4 的 `-x`,
且那里用的也是 `metadata().dev()` 而非挂载表)。

我们的 `Pulse/Live/DiskSensor.swift`(对账等纯逻辑现在核心层 `DiskModel.swift`)反过来全程不进目录树:`statfs("/")` 定容器 →
`getmntinfo` 全表 → 每卷 `getattrlist` 精确已用 → CFURL 两 key 差值 →
`fs_snapshot_list` → IORegistry 吞吐差分。两边唯一的共同底层动作是"取元数据
/statfs"这一族系统调用,用途完全不同。**对现有 DiskSensor:没有可替换、可移植
的东西,一条都不用改。**

## 2. 实现要点(带行号,`dust-ref` 为克隆根)

### 2.1 元数据与口径:block 为主,apparent 为辅,防异构文件系统虚报

`platform.rs:25-71` 的 `get_metadata`(Unix 路径,macOS 同用):

- 取法:`follow_links` 决定 `metadata()` 还是 `symlink_metadata()`(即 lstat),
  默认不跟随符号链接(`platform.rs:31-35`)。
- **block 口径(默认)**:占用 = `md.blocks() × 512`(各 Unix 实现的 block 恒
  512 字节,`platform.rs:7-11`)。稀疏文件、APFS 克隆在此口径下只算实际块。
- **虚报封顶**:NTFS 挂载会虚报 block 数(issue #295),封顶算法
  `target_size = file_size.div_ceil(blksize) × blksize`,再放宽
  `blksize × 65536` 的预分配缓冲,超出即用 target(`platform.rs:46-61`)。
  macOS 上挂网络卷/异构文件系统时同类虚报同样可能踩到。
- **apparent 口径(`-s`)**:直接 `md.len()` 文件长度(`platform.rs:38-44`),
  同时(见 §2.3)关闭硬链接去重——同一文件多条硬链接在 apparent 模式下故意
  各算一份。
- 返回 `(大小, (ino, dev), (mtime/atime/ctime))` 三元组,后两组供去重与
  时间过滤(`platform.rs:29`)。

启示:做"可回收空间"展示时 block/apparent 两口径必须分清文案;封顶逻辑是
跨文件系统场景的廉价保险。

### 2.2 遍历骨架:rayon 平铺任务,O(1) 栈深,重试安全的提交点

`dir_walker.rs:266-346` 的 `walk_dir`:

- 每个扫描根一次 `rayon::scope`,子目录经 `scope.spawn` 成为**平铺**的兄弟
  任务——不递归,栈深与树深无关(`dir_walker.rs:112-116`;旧版递归导致需要
  `--stack-size` 旗标,现已废弃并警告,`main.rs:267-272`)。
- 完成协调:`PendingDir` 父子链 + 原子计数,归零表示"本目录及全部后代完成",
  根经合成 outer 父节点走同一条 `finalize_chain` 上卷路径
  (`dir_walker.rs:56-107`)。
- 目录项处理:先 `read_dir` 全量收集进 Vec(`dir_walker.rs:290`),再
  `into_par_iter` 并行产出文件节点(`dir_walker.rs:323-332`)。"先收集后提交"
  是重试安全的关键结构:EINTR 重试时丢弃整个 Vec 重新列目录,没有已派生子任务
  需要回滚(`dir_walker.rs:286-305`)。文件节点由 rayon 的 collect 线程本地
  累积、一次 extend 合并,热循环无锁竞争(`dir_walker.rs:307-336`)。

### 2.3 硬链接去重:(inode, device) 后置遍历,顺序确定

`dir_walker.rs:133-170` 的 `clean_inodes`:遍历完成后自顶向下过滤,
`(inode, device)` 进 `FxHashSet`,已见即丢弃该节点(`dir_walker.rs:135-140`);
仅在 block 口径(非 apparent)下启用。子节点先 `sort_by_inode` 排序保证去重
结果确定(注释:按 inode 排序比按名字/大小快,`dir_walker.rs:142-148,
172-188`)。

### 2.4 不跨文件系统(-x):st_dev 集合剪枝,不解析挂载表

`-x` 的实现:对每个用户给的根路径取一次 `get_metadata(...).dev()`,收集成
`HashSet<u64>`(`main.rs:205-210` 调 `utils.rs:37-58` 的
`get_filesystem_devices`);遍历时子项 dev 不在集合内即剪枝
(`dir_walker.rs:219-226`)。集合为空(未开 `-x`)则不过滤。

对我们的启示:这比解析挂载表或设备名字符串便宜且稳。macOS 根卷与
`/System/Volumes/Data` 之间有 firmlink,同一段内容两条路径可达,naive 扫 `/`
会重复统计——st_dev 比对是最便宜的护栏(我们现有 `containerOf` 的设备名字符串
解析在监控场景没问题——那里本来就要枚举卷表拿每卷明细——但扫描场景用 st_dev
更合适)。

### 2.5 错误台账与重试上限:分类入册不中断

`dir_walker.rs:461-481` 的 `record_error`:PermissionDenied/InvalidInput 入
`no_permissions` 集、NotFound 入 `file_not_found` 集,目录照常下潜不中断;
EINTR 是唯一可重试错误,重试计数超 999 判定失控、打印后跳过该目录(注释记录了
阈值从 3 调到 999 的历史:有些系统常态性 EINTR,但无上限会死循环,
`dir_walker.rs:472-481`)。权限类有专门测试且 root 下跑会跳过(测试自己知道自己
在 root 下无权限错误可测)。

### 2.6 进度与线程池

- 进度:两个原子计数 `num_files`/`total_file_size`,`Ordering::Relaxed` 够用,
  每根扫描前清零(`progress.rs:60-72`)。
- 线程池:`rayon::ThreadPoolBuilder` 全局一次,`-T` 可调,默认 CPU 数
  (`main.rs:444-452`);README 明说高延迟存储(NFS)才值得加线程——本地 NVMe
  上加线程收益有限。

## 3. 与 petal scan 的分工(sensor-impl-comparison.md §2.1 已记后者)

若做空间扫描,macOS 主路径仍照 petal:dust 走 `std::fs` 逐文件 lstat、一次一个
syscall,是跨平台的代价;petal 的 `getattrlistbulk` 一次 syscall 拿整目录元数据、
iCloud dataless 目录跳过绝不触发回源、`ATTR_CMNEXT_PRIVATESIZE` 单独量 APFS
克隆共享字节——这三件 macOS 特化 dust 都没有,petal 的 `(dev, ino)` 去重也已
记录在案。dust 的增量贡献是**护栏类**:

| 借鉴点 | dust 出处 | petal 有无 |
|---|---|---|
| st_dev 集合防跨挂载点/firmlink 双计 | `utils.rs:37-58` + `dir_walker.rs:219-226` | 无(靠扫描锚定 Data 卷,无通用剪枝) |
| block 数虚报封顶(blksize 向上取整 + 预分配缓冲) | `platform.rs:46-61` | 无 |
| EINTR 重试上限(999)+ 权限/缺失分类台账 | `dir_walker.rs:461-481` | 无 |
| 重试安全的"先收集进 Vec 再提交"遍历结构 | `dir_walker.rs:286-332` | 无 |
| 进度原子计数(Relaxed) | `progress.rs:60-72` | 无 |
| 线程数可调、默认 CPU 数 | `main.rs:444-452` | rayon 默认 |

另注意我们的硬约束比 dust 严:常驻监控跑在用户主力机上,扫描必须低优先级、
可取消、限并发(内存教训:测试/扫描类负载用户敏感,短爆发+清理)。

## 4. 结论

- 现有 `Pulse/Live/DiskSensor.swift` 监控路径:**零改动**,dust 不碰我们赖以为生的
  任何口径(Finder 可用、purgeable、快照、内核 IO 账)。
- 空间分析功能(§8.1 可回收产物扫描 / per-app 占用)动工时再翻本文:主路径照
  petal,护栏抄 dust(§3 表),优先级:st_dev 剪枝 > 硬链接去重(已有 petal)>
  虚报封顶 > 错误台账/重试上限 > 进度/线程池纪律。
