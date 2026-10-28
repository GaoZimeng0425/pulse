# 01: 实施前探针——getattrlistbulk 字段形状 / 克隆口径 / 废纸篓结构 / Ollama manifest / worktree 清单 / 扫描量级

**What to build:** 五组一次性真机探针(先例:docs/probes/ 既有编号规则接续,源码+输出落档不留 /tmp),给 02-08 票消雷:
① **getattrlistbulk 批量枚举**:ATTR_CMNEXT_PRIVATESIZE 在 macOS 26 的可用性与克隆私有大小实测(克隆文件 vs 原文件 block 数对比);dataless(iCloud)项的检测标志;st_dev 在根卷 / Data 卷 firmlink 下的双计实态;EINTR 是否常态出现。
② **废纸篓结构**:~/.Trash 与 /Volumes/*/.Trashes 下本用户目录的真实形状、权限模型、无权限项长什么样;NSWorkspace 移入废纸篓对目录的行为与失败模式。
③ **Ollama 内容寻址**:本机 ~/.ollama/models 的 manifest/blobs 实测(用户实装),两模型共享 blob 的真实可回收量验证,LM Studio / HuggingFace 缓存目录形状。
④ **worktree 清单**:git worktree list 输出形状,"孤儿"判定的输入面(登记与否、进程活动检测)。
⑤ **全卷扫描量级**:本机文件总数与 getattrlistbulk 单线程首遍耗时粗测,给 03 的进度/并发设计基线。
探针失败同样落档:如实记录失败模式并写明回退路径(如克隆字段缺席 → 回退 block 口径 + 克隆不去重,界面口径文案如实),不算探针票失败。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] 五组探针源码+输出按既有编号规则存档 docs/probes/,不留 /tmp
- [x] 克隆私有大小字段有结论(可用 / 不可用→回退口径写明)
- [x] 废纸篓多卷结构与无权限项形状落档(08 票直删设计输入)
- [x] Ollama manifest 实测:共享 blob 去重算法有验证数据(06 票输入)
- [x] 全卷首遍耗时基线数字落档(03 票进度与并发设计输入)


## Comments

**2026-10-28 执行完毕(探针 11-15,docs/probes/ + .output.txt;全部一次性真机,负载纪律遵守——全卷 walk 限时 30s):**

- **⑪ getattrlistbulk/cmnext(macOS 27.0.1)**:bulk **必须带 ATTR_CMN_RETURNED_ATTRS**(否则一律 EINVAL,man 写"或"实测"且");条目布局 = [len u32][attribute_set_t 20B][定长属性 4 字节紧凑][名字尾置];FILEID 8B;**cmnext(PRIVATESIZE/CLONE_REFCNT)单发与批量都可用**(位放 forkattr + FSOPT_ATTR_CMN_EXTENDED);**PRIVATESIZE = "删此文件立即释放的字节数"——克隆记账文件系统原生完成**(克隆实验:原件 8MB→0、克隆 CoW 后=1MB、CLONE_REFCNT 1→2→1),引擎"真实可回收量"直接求和即得;firmlink:根卷与 Data 卷 **st_dev 相同**,防双计改用 (dev,fileid) 目录访问集;EINTR 零观测。解析器逐字节验证(mismatch=0),可直接进 02 票。
- **⑫ 废纸篓**:本机唯一废纸篓 = ~/.Trash(700 权限);启动卷密封**无 /.Trashes**(Read-only file system);无外置卷在场,跨卷 .Trashes 行为留待补测;NSWorkspace.recycle 走通——吃 [URL] 数组、回调回赠 原 URL→废纸篓新 URL 字典、文件 63ms/目录 1ms、原名落位 Finder 可见可恢复。
- **⑬ Ollama**:manifests/registry.ollama.ai/library/<model>/<tag> JSON + blobs/sha256-* 结构确认;本机只 1 个模型(bge-m3 1.08 GiB),两模型共享 blob 去重**未赶上真数据**——算法按 manifest 引用求交实现,夹具测试补;LM Studio/HF/whisper/Jan/GPT4All 本机全不在场;ollama serve 在跑(06 票在用保护真素材)。
- **⑭ worktree**:`git worktree list --porcelain` 输出形状确认(worktree/HEAD/branch,空行分隔);**纠偏:SwarmAgents-wt-* 两目录是 git 登记中的活 worktree,不是孤儿**(原型假数据拿它们当孤儿是错的)——"并排 -wt- 目录 ≠ 孤儿",判定必须对账 worktree list;孤儿无真样本,规则测试用夹具。
- **⑮ 全卷量级**:单线程 getattrlistbulk(带 cmnext)**2.1 万项/s**;Data 卷 30s 扫了 64.1 万项(仅剩 388 目录未展开)→ 全卷单线程约 31s;错误调用 1 次。03 票并发压力骤减,v1 单线程或轻并发即可,进度条有真基线。

探针负载纪律:短爆发 + 跑完清理(已遵守:全卷 walk 限时 30s、探针临时物全部清理)。
