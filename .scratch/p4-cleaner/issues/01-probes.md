# 01: 实施前探针——getattrlistbulk 字段形状 / 克隆口径 / 废纸篓结构 / Ollama manifest / worktree 清单 / 扫描量级

**What to build:** 五组一次性真机探针(先例:docs/probes/ 既有编号规则接续,源码+输出落档不留 /tmp),给 02-08 票消雷:
① **getattrlistbulk 批量枚举**:ATTR_CMNEXT_PRIVATESIZE 在 macOS 26 的可用性与克隆私有大小实测(克隆文件 vs 原文件 block 数对比);dataless(iCloud)项的检测标志;st_dev 在根卷 / Data 卷 firmlink 下的双计实态;EINTR 是否常态出现。
② **废纸篓结构**:~/.Trash 与 /Volumes/*/.Trashes 下本用户目录的真实形状、权限模型、无权限项长什么样;NSWorkspace 移入废纸篓对目录的行为与失败模式。
③ **Ollama 内容寻址**:本机 ~/.ollama/models 的 manifest/blobs 实测(用户实装),两模型共享 blob 的真实可回收量验证,LM Studio / HuggingFace 缓存目录形状。
④ **worktree 清单**:git worktree list 输出形状,"孤儿"判定的输入面(登记与否、进程活动检测)。
⑤ **全卷扫描量级**:本机文件总数与 getattrlistbulk 单线程首遍耗时粗测,给 03 的进度/并发设计基线。
探针失败同样落档:如实记录失败模式并写明回退路径(如克隆字段缺席 → 回退 block 口径 + 克隆不去重,界面口径文案如实),不算探针票失败。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] 五组探针源码+输出按既有编号规则存档 docs/probes/,不留 /tmp
- [ ] 克隆私有大小字段有结论(可用 / 不可用→回退口径写明)
- [ ] 废纸篓多卷结构与无权限项形状落档(08 票直删设计输入)
- [ ] Ollama manifest 实测:共享 blob 去重算法有验证数据(06 票输入)
- [ ] 全卷首遍耗时基线数字落档(03 票进度与并发设计输入)

## Comments

探针负载纪律:短爆发 + 跑完清理,不在用户主力机上长时间满载(全卷扫描量级测一个可中断的单遍即可)。
