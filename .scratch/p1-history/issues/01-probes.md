# 01: 三项探针——钉死三卡实现路径

**What to build:** 三个单文件 Swift 探针在本机跑出纸面结论,写回调研文档 §5 的开放问题,决定磁盘卡与网络卡的实现路径与回退条件:①purgeable 两口径对照(CSDiskSpace vs CFURL 两 key 差值)同刻输出,哪个与 Finder 一致;②fs_snapshot_list 在 macOS 26 是否仍免 root 可列;③IORegistry 块存储驱动统计对本机 NVMe 的覆盖(kIOBlockStorageDriverStatisticsKey 是否有值)。

**Blocked by:** None (can start immediately)

**Status:** done (2026-10-16,本机 macOS 26 实测)

- [x] 三个探针脚本入库,原始输出留档
- [x] 调研文档 §5 问题 3/4 标注结论(问题 3 即探针①,4 即②),IORegistry 覆盖补记
- [x] 磁盘卡容量/purgeable 口径选定(以与 Finder 一致者为准)
- [x] 吞吐路径选定:IORegistry 可用则走之;不可用则写明回退 rusage 求和 + 30s 低频档

## 探针结论(详见调研文档 §5.3/5.4/5.10 与 docs/probes/*.output.txt)

1. **purgeable 两口径一致,且 Finder = petal 口径**:同刻 `CSDiskSpaceGetRecoveryEstimate` 与两 key 差值均为 6.61 GB(Δ=0.00);osascript 同刻问 Finder 得 209.55 GB,与 `volumeAvailableCapacityForImportantUsageKey` 分毫不差(裸 statfs f_bavail=202.9 GB 是另一档)。→ 05 用 petal 两 key 差值,不引 CoreServices 的 CSDiskSpace。
2. **fs_snapshot_list 免 root 可列成立**:uid=501 下 Data 卷 rc=0(空列表,tmutil 交叉确认),根卷列到 `com.apple.os.update-*`;attrlist 缺 RETURNED_ATTRS → EINVAL,petal 三件套要求照搬;成功时 errno 是残留值,判成败看返回值。
3. **IORegistry 吞吐对 NVMe 覆盖成立**:NVMe 驱动 Statistics 的 `Bytes (Read)`=3747 GB / `Bytes (Write)`=1888 GB 且 2s 有增量(系统级内核账,免 root);键名是 `"Bytes (Write)"`;卷→驱动的 stats 式向上遍历从 `disk3s1s1` 命中。

## 对 05/06 的路径决定

**05 磁盘卡**(解锁,可开工):
- 容量对账:petal 算法不变;**可清除空间 = 两 key 差值**(petal,`docs/probes/01-…swift` 即实现骨架),与"实际可用"分开文案。
- 快照列表:`fs_snapshot_list` 直用(探针②即实现骨架),attrlist 必须带 RETURNED_ATTRS/NAME/CRTIME;**回退条件**:调用 rc=-1(如未来权限收紧/EACCES)或目标卷非 APFS → 快照行显示占位"不可用",不伪造。
- 系统读写速率:**主路径改走 IORegistry 内核账差分**(stats `Modules/Disk/readers.swift:248-321` 翻译,探针③已验证卷→驱动遍历与本机计数器);**回退条件**:目标卷向上遍历失败(非典型栈:部分 RAID/外置盒)或 `Statistics` 缺 `Bytes (Read)`/`Bytes (Write)` 键 → 该卷回退 rusage 求和 + 30s 低频档(工单原文预案保留为回退)。

**06 网络卡**(与三项探针无直接耦合,01 完成即解锁):按调研文档 §2.2 实装——NET_RT_IFLIST2 差分三件套 + 主接口选择/虚拟前缀降级,无路径变更。
