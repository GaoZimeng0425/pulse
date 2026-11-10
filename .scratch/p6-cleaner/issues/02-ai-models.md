# p6-cleaner/02:AI 模型域(存储位 + 内容寻址真实可回收 + 在用第四路)

Status: ready-for-agent
Blocked by: 01

## 目标

复活 p4-cleaner/06:`aiModels` 组四条规则 + Ollama 内容寻址真实可回收量 + 在用保护第四路(服务进程)。

## 范围

1. 四条规则全「先检查」:`~/.ollama/models`、`~/.lmstudio/models`、`~/.cache/huggingface`、GPT4All 常用位(`~/Library/Application Support/GPT4All`);不在场不列、规则照登记。
2. Ollama 内容寻址(纯值进 PulseCore):`manifests/<registry>/<model>:<tag>` → layers blob 清单,按 digest 去重求和 = 真实可回收(共享层不重复计);大小口径仍走扫描树(blobs 是普通文件),manifest 解析只决定「哪些 blob 计入」。非 Ollama 存储位整目录口径。
3. 在用保护第四路:ollama 服务进程在跑(进程名 / argv 命中)→ AI 组候选在用灰行;接 `CleanActivitySource` 既有管线(判定不缓存、删除前重查照旧)。
4. 防线沿用:确认单 / 废纸篓 / 历史(ruleID `ai.ollama` 等)/ 右键排除;登记完整性正例。

## 验收

夹具:两模型共享一层 → 可回收 = 私有层之和 + 共享层只计一次;ollama 进程在场 → 灰行;manifest 缺失 / 损坏 → 整目录口径兜底并如实标注。

## Comments

- 2026-11-10 实施(前任代理完成主体,接手者收尾:现场核验 / 补跑门禁 / 提交记档;bf86b4a):
  - **规则**:AI 组四条存储位规则(`ai.ollama` / `ai.lmstudio` / `ai.huggingface` / `ai.gpt4all`,全「先检查」)进 `JunkRuleTable.aiModelRules` 并入 `builtin`;正例 + 似是而非(`.ollama/models-old` 等)进 `JunkRuleTableTests`;01 的空组断言改写为四规则护栏。`ai.ollama` 的 id 单一出处 = `OllamaStoreAccounting.ruleID`。
  - **Ollama 记账**(新纯值文件 `CleanAIModels.swift`):计入集 = 全部清单 config+layers digest 并集 + manifest 文件本身;共享层按 digest 去重只计一次,无主 blob 不计入;字节一律取扫描树节点(实际占用口径不变)。**兜底方向拍板**:manifest 缺失 / 损坏 / 零有效清单 / 旧缓存无文件明细 → 整目录口径 + `accountingNote`(「模型清单不可用,按整目录计」)如实标注——宁可说全,不按残缺引用集给小数字。
  - **扫描引擎**:`SpaceScanOptions` 新增 `retainedFilePrefixes`(`retainFileNodes=false` 时的定向例外,前缀出处单一);空间地图 `mapChild` 显式跳过文件节点(目录粒度设计)。
  - **在用第四路**:`aiServiceExecutables`(基名命中 executablePath / argv[0])→ home 锚上挂 `.aiService` 标记(新原因位,`CleanActivityReason` 1<<4);`CleanInUse.reasons(for:entries:)` 组感知版——AI 组吃标记、他组不越组、对路径前缀判定惰性(home 祖先方向本就不匹配);MCP 侧沿用路径版(AI 恒先检查永不进 MCP 安全档)。`LiveCleanActivitySource` 默认参数传 home,装配点零改动。
  - **为何动 `CleanerModel.swift`**(另一分支也改此文件,合并解冲突用):① `init` 新增 `aiManifestReader` 注入缝(默认 FileManager 读 manifest,测试注入字典);② 扫描选项传 `OllamaStoreAccounting.retainedFilePrefixes(home:)`(文件节点进树,记账才有数);③ `computeCandidates` 里 JunkMatcher 产出过一遍 `OllamaStoreAccounting.applied(to:in:readManifest:)`;④ `inUseReasons`(单参 / 双参)与 `plan` 换调组感知 `CleanInUse.reasons(for:)`(灰行 + 在用剔除)。四处都是本票专属增量,未动 03 侧总览 / 排序逻辑。
  - **为何动 `CleanerJunkViews.swift`**(同上,另一分支也改):仅 `JunkRow` 行副标 parts 追加 `accountingNote`(「部分扫描」之后),兜底口径对用户可见;沿用既有副标惯例,零新行形态、零新 token。
  - **测试**:核心包 `AIModelDomainTests` 7 例(共享层只计一次 / 四路兜底 / 文件保留前缀 / 第四路汇入不越组 / 无 home 行为不变 / 原因并集)+ app 侧 `CleanerModelTests` 2 例端到端(记账 + 服务在跑灰行 + 在用计划剔除 + 判定不缓存 / 损坏兜底标注)。门禁:核心包 710 · app 侧 480 · 合计 1190 全绿(本 worktree 直跑未复现宿主挂起;`sh scripts/lint.sh --staged --fix` 过)。
  - **偏离项**:无——四条范围全按票落地;ruleID `ai.*` 落历史零迁移(自由文本列),确认单 / 废纸篓 / 右键排除 / 删前重查零改动自动生效。
