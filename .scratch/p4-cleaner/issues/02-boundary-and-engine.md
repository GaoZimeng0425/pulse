# 02: 清理系统边界协议 + 扫描引擎内核(纯值,PulseCore)

**What to build:** 本批唯一新接缝(spec 实现决定,用户已确认 2026-10-28)——「清理系统边界」协议,三件事:①目录枚举(元数据批:名 / 大小 / ino / dev / 是否目录 / dataless / 克隆私有大小)②移入废纸篓与清空废纸篓 ③查询"此刻哪些路径有进程活动";同票交付测试用假实现(内存文件系统夹具 + 废纸篓 spy + 活动表)。纯值扫描引擎:目录批次流 → 空间树;实际占用口径(block 为主、(dev, ino) 后置去重、克隆按 01 探针结论两分支)、st_dev 剪枝(防根卷 firmlink 双计)、部分扫描 / 错误台账(权限 / 缺失分类入册不中断、绝不出现假 0)、进度与中途取消(取消后已产出部分树如实标注)。全部测试打在合成夹具上,零真盘 I/O。

**Blocked by:** 01(引擎元数据形状由探针结论钉死)

**Status:** done

- [x] 协议三件事齐;测试假实现(内存 FS / 废纸篓 spy / 活动表)同票交付
- [x] 口径测试:硬链接去重、克隆口径(按 01 结论的双分支)、跨挂载剪枝
- [x] 部分扫描台账:读不了的目录标 partial、汇总时如实上报,不出现假 0
- [x] 进度 / 取消语义测试:中途取消后已扫部分可用且标注不完整
- [x] PulseCore `swift test` 全绿,零真盘 I/O(测试负载最小化纪律)


## Comments

**2026-10-28 实施完毕(feat/p4-engine,13 例新测试,包内 467 例全绿):**

- **交付**:`CleanBoundary.swift`(FsEntrySnapshot 快照形状 + 三协议:CleanDirectoryEnumerator / CleanTrashExecutor / CleanActivitySource + 废纸篓战报类型)、`SpaceScanEngine.swift`(纯值引擎:空间树 / 台账 / 进度 / 取消 / 排除 / 深度护栏)、TestSupport `CleanFixture.swift`(内存 FS 假实现 + spy + 活动表,04/05/08 票测试继续取用)、13 例引擎测试。
- **口径落地**:每文件 reclaimableSize(PRIVATESIZE)优先、allocatedSize(block)回退,节点带 allReclaimableAccounting 标志如实区分;绝不伪造 0。
- **探针 11 修正落码**:验收项原文写的"跨挂载剪枝"(dust 假设)在 27 上前提不成立(根卷/Data 同 dev)——防双计改为 (deviceID, fileID) 目录访问集 + 文件硬链接同键去重,测试用 firmlink 双路径与重叠根双例钉死。验收项按此意图勾选。
- **取消语义拍板实现**:取消点在每个目录入口;取消后已产出(部分)树保留可用、结果标 cancelled、不再枚举新目录——03 票进度条直接挂 progress 回调(每 2048 项 + 收尾)。
- 排除根静默跳过(用户意图不进台账);枚举失败四分类入册(permissionDenied / vanished / tooDeep / other);符号链接不跟随零贡献;iCloud dataless 单独计数。
