# 02: 项目产物分组键改父目录完整路径

**What to build:** 用户实报(2026-11-09 截图):大卡分组归属错乱——「明明不是一个文件夹路径却是一个父级,明明是一个文件夹路径却不是一个父级」。

1. 根因:`ProjectArtifactMatcher.artifacts` 的分组键 `projectName: node.name`(`CleanProjectArtifacts.swift` ~227)只取产物直接父目录的**名字**(路径末段)。截图实锤:SwarmAgents / ZCode / 两个 SwarmAgents-wt-* 四个不同仓库的 `apps|packages/desktop` 产物并进同一张 `desktop` 卡;反方向,同一仓库根下产物归「仓库名」卡、子目录产物归「子目录名」卡,一项目拆多卡。
2. 历史:11-05 曾从「DFS 顶层项目名」改成「直接父目录名」修 worktree 冒名(worktree 产物全标主项目名)——修一头漏一头;完整路径键两头都对:同路径必同卡,异路径必异卡(worktree 路径天然不同,老病不复发)。
3. 修复:`projectName` 改携带 `node.path`(父目录完整路径);`JunkCandidate.projectName` 文档改口径(大卡分组键:项目产物 = 父目录完整路径;卸载残留 = 完整 bundle id,OrphanLeftovers 语义不动)。显示:卡头大字 = 路径末段(`lastPathComponent`),元信息行前置完整路径(既有 middle 截断兜长路径);收起键 cardKey 随 projectName 变完整路径,天然不串。缓存存的是扫描树、候选每次现算,旧缓存重开即按新键分组,无需升缓存版本。
4. 测试:`ProjectArtifactTests` 既有断言(`old-app`/`new-tool`/`dev`)改完整路径;新增用例:两个不同仓库的同名子目录(`a/apps/desktop` vs `b/packages/desktop`)必须分属两组。

**Status:** done(2026-11-09,分支 fix/cleaner-junk-card-fixes)

## Comments

**2026-11-09 实施记录:**

- 改动点:`CleanProjectArtifacts.swift` 一处赋值 + 注释、`JunkRules.swift` 字段文档、`CleanerJunkViews.swift` 卡头显示(末段)与 `projectMeta`(完整路径;与卸载残留的 bundle id 前缀合流成同一行代码)。
- `JunkPresentationTests`(分组语义本身)零改动——`ProjectJunkGrouping.group` 仍按字符串键聚合,只是键值从名字变成路径。
- 测试:核心 ProjectArtifactTests 15 例全绿(新增同名异路用例);/tmp detach worktree 全量 check 绿 1156/1156(首跑在 Documents worktree 挂宿主连接,已知间歇问题,记录见 01 票)。
