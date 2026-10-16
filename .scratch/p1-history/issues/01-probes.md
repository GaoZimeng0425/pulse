# 01: 三项探针——钉死三卡实现路径

**What to build:** 三个单文件 Swift 探针在本机跑出纸面结论,写回调研文档 §5 的开放问题,决定磁盘卡与网络卡的实现路径与回退条件:①purgeable 两口径对照(CSDiskSpace vs CFURL 两 key 差值)同刻输出,哪个与 Finder 一致;②fs_snapshot_list 在 macOS 26 是否仍免 root 可列;③IORegistry 块存储驱动统计对本机 NVMe 的覆盖(kIOBlockStorageDriverStatisticsKey 是否有值)。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] 三个探针脚本入库,原始输出留档
- [ ] 调研文档 §5 问题 3/4 标注结论(问题 3 即探针①,4 即②),IORegistry 覆盖补记
- [ ] 磁盘卡容量/purgeable 口径选定(以与 Finder 一致者为准)
- [ ] 吞吐路径选定:IORegistry 可用则走之;不可用则写明回退 rusage 求和 + 30s 低频档
