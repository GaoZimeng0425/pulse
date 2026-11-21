# 01: SOLID 文件级拆分——视图/账本大文件分居(纯搬运)

**What to build:** 把行数榜前几名的混居文件按职责分文件(纯搬运,零逻辑改动):
CleanerJunkViews 1193→五、AgentUsageModel 911→四、CleanerAppViews 803→三。
唯一允许的变换 = 跨文件引用的 `private struct` 升 `internal`(可见性放宽)。

**背景:** 2026-11-22 深查定位的 S 违例;用户拍板「开工,先把债还了」。
验证口径 = 纯搬运 + 全量 check 全绿(diff 逐块核对无逻辑行变化)。

**Status:** done(2026-11-22;A 批 merge@031a44b:JunkViews 五件/UsageModel 四件;
B 批 AppViews 三件)

- [x] A1 CleanerJunkViews → 共用件/清单卡/行家族/确认 sheet/历史子页(1c01f5b)
- [x] A2 AgentUsageModel → 模型+样本/解析器/聚合+合并/落库+接缝(100209f;
      核心 44 例 agent 测试绿)
- [x] B CleanerAppViews → 清单/行+残留区/确认 sheet+搜索框

**Out of scope(见 02):** CleanerModel(986)与 CleanerSpaceMapView(847)——
分别是 @Observable 六职责中枢与单 struct 767 行大视图,**文件级拆分还不了
它们的债**(状态封装/视图组合结构),需类型级手术,另票。

## Comments

- **流程插曲(如实记):** A 批首版脚本相对路径落错 checkout,且 `git add -A`
  吃错 cwd 把成果直接误提主仓 develop(c67c234,未推送窗口内 reset 补救,
  worktree 重做后走正规 merge)。坑档案(scripted-swift-edit-pitfalls)已升
  终版纪律:批量脚本路径一律绝对路径常量;提交命令以 `cd <worktree 绝对路径> &&`
  开头。当晚后续又犯一次变种(哨兵目录下嵌套建 worktree),均已当场纠正——
  「清理命令 cd 主仓开头」与「worktree add 用绝对路径」两条并入同档。
