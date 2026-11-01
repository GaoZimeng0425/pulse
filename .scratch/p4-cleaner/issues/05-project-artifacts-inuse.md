# 05: 项目产物 + 在用保护 + 清理扫描根配置

**What to build:** 清理功能单独一套扫描根(用户拍板,不复用归组项目根,两套配置解耦):设置页给常见开发目录建议清单、勾选 + 自添(用户需自加 ~/Documents/Learn/macos)。项目产物规则域(node_modules / target / Pods / venv / build / dist 等)按项目分组;默认显示全部、默认按大小排序可切新旧(用户拍板);项目年龄 = 项目内任何文件的最后变动(含 git 活动),不看产物自身 mtime(重装依赖不刷新年龄)。在用保护(三路):进程 cwd / argv 命中 + 构建进程特征 + git 活动;扫描时判定一次影响展示,**删除前重查一次、判定永不缓存**;在用行灰显并给原因(如 pulse 行显示"终端与构建正在此项目")。

**Blocked by:** 04

**Status:** done(2026-11-01,develop@2bd4f8f)

- [x] 扫描根独立配置、建议清单可勾选追加;归组配置零改动(用户拍板 1B)
- [x] 项目分组正确;年龄口径测试:夹具里重装依赖(mtime 新)不改变项目年龄
- [x] 在用项目绝不出现;删除前重查有测试(扫描后新开终端进项目 → 确认时被剔除)
- [x] 判定不缓存:两次操作之间活动变化被反映
- [x] 显示全部 + 默认全不勾;排序按大小可切新旧
- [x] 进程活动输入走既有采样快照通路,零新采集

## Comments

- **交付(2026-11-01,02b87a4)**:纯值层 `CleanProjectArtifacts.swift`(规则表 9 条
  + 登记完整性测试:node_modules/Pods/venv/.venv/target/.build/.next 安全,
  build/dist 先检查——名字可能装源码)+ `CleanActivity.swift`(三路推导 + 方向判定)。
  年龄口径的实现关键:`SpaceNode.newestChangeEpoch` = **直属文件** mtime 最大值
  (不聚合子孙),匹配器 DFS 跳过产物子树再逐层取值——聚合口径会把产物 mtime 卷进
  项目年龄(重装依赖会刷),直属口径 + 跳产物 = 精确无泄漏;目录自身 mtime 引擎侧
  就不算(rm -rf node_modules 再装会刷目录条目)。mtime 进边界:FsEntrySnapshot.
  modifiedEpoch(getattrlistbulk ATTR_CMN_MODTIME 0x400,打包位 OBJTYPE 后无垫,
  /tmp/mtime-probe 逐字节对拍 stat 定谳后才动 Live 枚举器)。
- **在用保护**:活动协议升级 `activeEntries() -> [CleanActivityEntry]`(带原因:终端/
  构建/git/argv 引用);推导只发**已分类进程**的 cwd——守护进程的家目录 cwd 不许
  保护整个家目录(purge-app process-cwd-in-project 口径 + 未分类过滤);方向 = 活动
  落在候选**之内**才保护(父目录活动不保护子项目)。Live 侧零新采集:SystemMonitor
  每轮 apply 把快照三元组投影进 `CleanActivityBoard`(HeartbeatRusageRelay 同款),
  `LiveCleanActivitySource` 每次调用现推导。项目产物按**项目目录**判保护(终端在项目根
  = 保护全部产物);`plan` 现查过滤(requestClean / confirmClean 各一次,判定永不缓存);
  在用行整行 55% 灰 + 锁标 + InUseChip(灰,区别于「先检查」琥珀),不可勾不可组勾选。
- **扫描根**:`CleanScanRootsStore`(键 cleanerScanRoots;与归组 projectRoots 两套零共享,
  测试钉死键名互异);设置「清理」建议清单(~/Documents 等 8 项勾选即加)+ 自添选择器;
  清单页未配根出引导文案。归组配置零改动 ✓。
- **测试**:核心 16 + app 7(存储 5 + 端到端 2:①夹具重装依赖(mtime 新)年龄不变、
  大小⇄新旧排序;②扫后新开终端 → inUseReasons 翻转、计划即刻剔除、确认执行只到
  不在用项)。全量 938 例 /tmp worktree 验证——`.worktrees` 里 hosted 挂死复发
  (connection-then-TERM 272s,[[hosted-tests-hang-under-documents]] 第三次),按既定
  回退跑 /tmp 全绿。VStack→LazyVStack 两处收编(04 挂账清零)。
- **欠目验(用户)**:设置 → 清理 → 勾选或自添 `~/Documents/Learn/macos` → 清理页扫描 →
  ①项目产物组出现 pulse 等项目的 node_modules/.build(本会话在跑 → pulse 行应在用灰显
  「终端与构建正在此项目」且不可勾);②其他项目行可勾、年龄人话;③组头「大小|新旧」
  切换;④扫描后 cd 进某个项目再点「清理…」→ 确认清单里该项目消失(删除前重查)。
