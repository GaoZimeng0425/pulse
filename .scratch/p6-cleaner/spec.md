# p6-cleaner:清理深化 · 二期(扫描范围扩充 + 总览重排)

Status: ready-for-agent(2026-11-09/10 三轮 HTML 原型拍板;原型存档分支 `prototype/cleaner-reorg`)

## Problem Statement

两件事互为因果:①扫描范围窄——只认 15 条工具缓存 + 9 种项目产物 + 卸载残留,装着的 app 缓存、浏览器缓存、日志、AI 模型全不在场(2026-11-09 真机探针:~/Library/Caches 10 GiB 只认得 ~2.5,Caches 外另有 ~/.cache 2.7、~/.cargo 1.8、~/.ollama 1.1 全漏);②页面按「从哪来」分三组、总量只是卡头一行小字,打开没有「能省多少」的第一眼。用户拍板丙案:总览 + 品类大模块卡,品类从 3 组扩到 6 组。

## 产品主线

用户点「扫描整台 Mac」→ 落在清理页新子页「总览」:Hero 卡(可回收总量大数字 + 安全构成条 + 「一键清理 X 安全项…」主按钮)+ 六张品类大卡 + 一张废纸篓卡(带「清空废纸篓…」)。点大卡 → 「全部清单」按该品类过滤(分组 + 项目大卡形态沿用现状),勾选/确认单/移废纸篓与现状同一闸门。

## 定案(原型三轮,2026-11-09/10)

### 页面(丙案 v2,交互原型已验收)
1. 子药丸扩为五个:「**总览** | 全部清单 | 空间地图 | 应用 | 清理历史」;首个子页由「可清理」改名「**全部清单**」(内部标识 `CleanerSubTab.junk` 不动,文案层改名,同 p4-uninstaller/08 先例)。总览为新 case。
2. **Hero 卡**:可回收总量大数字(FigureSize 族)+ 构成比例条(positive/caution/inactive 三段)+ 图例(含「另有废纸篓 X」)+ 主按钮「一键清理 X 安全项…」(accent-clean,.large)。
3. **模块大卡**(2 列自适应,最小窗 1 列):42pt 图标瓦(类别色)+ 类名 16 bold + 一句人话(原型文案为蓝本)+ 24pt 大数字 + 构成条 + 「最大一项:名称 · 大小」行 + chevron。整卡可点 = 下钻。
4. **七张卡**:开发工具 / 浏览器 / 应用缓存 / 项目产物 / AI 模型 / 卸载残留 / 废纸篓。废纸篓卡非白名单候选(读数 + 独立「清空废纸篓…」按钮,复用 TrashExecutor 汇总),页头原废纸篓按钮撤除。
5. **下钻**:全部清单页顶部「‹ 总览」返回行 + 当前品类标题与合计;清单组段按品类,项目产物/卸载残留仍按所有者大卡(现状形态)。总览↔清单切换不丢勾选。
6. **一键清理安全项**(修订 p4 spec 故事 4,记 supersede):= 全选全部「可安全清理」且非在用项 → 弹既有确认单(逐行 + 总量,不变)。默认勾选仍全不勾;「先检查」永不进自动勾选。安全边界零变化:白名单 + 废纸篓 + 确认单 + 在用保护 + 删前复核。
7. 新数值 token(模块卡最小宽/图标瓦/构成条/hero 内距等)先补 DESIGN.md 表再写码;列表行继续走 RowMetrics/CleanerListMetrics,零新行形态。

### 扫描范围(全部走既有白名单模式;未识别目录仍不列,ADR-0008 原样)
8. `JunkGroup` 扩为六组(穷举 switch 与登记完整性测试强制表态):`globalToolCache`(开发工具,现有)/ `browserCache` / `appCache` / `projectArtifacts`(现有)/ `aiModels` / `uninstallLeftovers`(现有)。UI 组序同上;`groupsByOwner`:项目产物 + 卸载残留 = true,其余 false。
9. **浏览器缓存**(safe):已知浏览器在 `~/Library/Caches` 的目录规则(Arc / Dia / Chrome / Chromium / Edge / Brave / Firefox / Zen / Opera …)+ Application Support 下 Chromium 系缓存目录(`Local State` 标记 + 缓存目录名,purge-app `CacheDiscoveryPaths` 机制移植)。规则表移植自 purge-app(explanations.json,MIT,注明出处)。
10. **应用缓存**(逐条定档):`~/Library/Caches` 一级目录 × 知识库(认得出的定 safe/先检查;**认不出 v1 不列**)+ `~/Library/Logs`(应用日志,safe)+ `~/Library/Logs/DiagnosticReports`(崩溃报告,safe)。CloudKit 等系统关联缓存 = 先检查。知识库首批 = purge-app explanations 285 条中文化收编 + Pulse 自定条目,每条带 rationale。
11. **AI 模型**(复活 p4-cleaner/06,全「先检查」):`~/.ollama/models`(内容寻址 manifest 解析真实可回收量,共享 blob 不重复计)/ `~/.lmstudio/models` / `~/.cache/huggingface` / GPT4All 常用位。在用保护扩展第四路:**ollama 服务进程在跑 → AI 组在用**(进程名/argv 命中;后续可精化为 /api/ps)。
12. **开发工具规则扩充**(纯加行,不新组):`~/.cargo/{registry,git}`、`~/.cache/uv`、`~/go/pkg/mod` + `~/Library/Caches/go-build`、`~/.m2/repository`、`~/Library/Caches/pnpm`(真案漏网:pnpm 元数据缓存与 store 是两处)、Xcode Archives(先检查)、XCTestDevices(先检查)、Corepack/Yarn/Deno/Bun 常用位。首批挑本机在场 + purge-app 高频条目,不求 56 条全搬。
13. 机制零改动沿用:两档安全标签、默认全不勾、确认单、移废纸篓、清理历史(新组 ruleID 随组扩展,去向复用 `.recycled`)、右键排除、在用三路 + 删前复核(p5-cleaner/03)、排除目录、实际占用口径、缓存复用。
14. MCP 侧不动:AI 经 MCP 真清理已上线(mcp-clean,只安全档 + app 确认单),与本批 UI 改动正交。

## 来源与参考纪律
- 原型:`prototype/cleaner-reorg`(分支)——甲乙丙三案 + 丙 v2 大卡,数据为真机探针实测;裁决:丙 + 大卡。
- purge-app(MIT):规则表与 explanations 知识库可直接移植,逐条注明出处;purrge(PolyForm)/CleanMyMac(闭源)只借品类划分与档位思想,零搬码。
- 真机缺口实测存档于本 spec Problem Statement(2026-11-09,du+mtime+孤儿粗筛探针)。

## Testing Decisions
- 规则表:登记完整性测试(每条内置规则至少一个正例,新增不写用例过不了);新组穷举表态(groupTitle/groupsByOrder/groupsByOwner)。
- 总览聚合进 PulseCore 纯值(`swift test` 不起宿主):品类聚合模型(总量/构成/最大一项/废纸篓读数)+ 全部清单过滤纯值;夹具直接用原型那批真机数据。
- 一键清理安全项:计划生成纯值断言(只含 safe 非在用;先检查/在用绝不在内)。
- UI 薄壳:子页枚举/导航/卡注册走既有结构性断言(MetricTabCleanerAxisTests 套路);观感目验归收口票(用户有眼睛)。
- 全量 check 用户发起(纪律不变)。

## Tickets(待拆,下一提交)
- 01 规则域扩充——浏览器/应用缓存知识库 + 开发工具补行 + 新组穷举 + 登记测试
- 02 AI 模型域——四存储位 + 内容寻址真实可回收 + 在用第四路(服务进程)
- 03 总览页——Hero/七模块卡/下钻导航/DESIGN.md 补表/废纸篓卡与页头按钮迁移
- 04 一键清理安全项 + 故事 4 supersede 落档 + 收口目验

## Out of Scope(记录不实施)
阈值式未知大目录发现(purrge「≥1GB 先检查」,待与 ADR-0008 白名单字面口径单独拍)/ Downloads 安装包与大文件 / AI 分析类 MCP 工具深化 / 低空间告警闭环(purrge-1)/ 自动定时清理(永久立场)/ 地图直删。
