# 04: 删除安全骨架闭环——全局工具缓存清单 → 确认 → 废纸篓 → 清理历史

**What to build:** 本批最核心的一张票,打通第一条完整竖井。白名单规则表机制(路径模式 + 安全档 + 说明文案 + 来源;未命中模式的目录不进清单)与首批规则域 = 全局工具缓存(Xcode DerivedData / DeviceSupport、Homebrew、npm、pnpm、CocoaPods、Gradle、JetBrains、VS Code / Cursor;Docker Desktop 数据以「先检查」档列出并写明"删除后镜像与容器全部丢失";规则数据可移植 purge-app,注明 MIT 出处)。开发者垃圾清单 UI:行 = 一个可删单元(图标 / 名称 / 路径 / 档位标签 / 大小 / meter),默认全不勾,先检查默认不勾;勾选动作条(已选 N 项 · 共 X GB → 清理…);确认清单(逐行 + 总量 + 实际占用口径注记);确认后 NSWorkspace 移入废纸篓(失败项如实报);GRDB 历史库加表(一次清理一行 run + 逐项一行 item:路径 / 大小 / 档位 / 去向),永久保留;右键排除 + 设置页管理(排除只收窄,扫描与删除两处生效)。规则登记完整性测试:每条内置规则必须被至少一个正例命中,新增规则不带用例过不了测试。

**Blocked by:** 03

**Status:** done

- [x] 清单只含白名单命中项;未识别目录不出现(夹具测试含"似是而非"目录)
- [x] 默认全不勾;确认清单逐行 + 总量 + 口径;确认后文件真进废纸篓(Finder 可恢复)——前两项测试钉死,**真进废纸篓交用户目验**(探针 12 已证 recycle 路径,测试纪律绝不真删)
- [x] 清理历史逐项落库;历史写入与清单内容一致
- [x] 右键排除立即生效(再扫描不出现)、设置页可管理;排除只收窄有测试
- [x] 登记完整性测试:故意加一条无正例规则必须红
- [x] 核心逻辑测试全在 PulseCore 夹具;废纸篓执行用 spy 断言路径,绝不真删

## Comments

小拍板留实施时问用户(一次一个):清单要不要「整组勾选」快捷键(原型备注的设计余地,不影响骨架)。

**2026-10-28 实施完毕(feat/p4-junk,新增 40 例测试,全量 892 绿:核心 506 + app 386):**

- **先量后动(交接 ⚠️)**:合成探针 `/tmp/p4-mem-probe.swift`(SpaceNode 同形状节点,真机量级 340 万项)——文件级节点全量驻留 **≈900 MB(278 B/节点)**,只留目录(≈10%)**≈90 MB**。落码为 `SpaceScanOptions.retainFileNodes`(默认 true 保 02 树形状;清理页传 false),目录上的计数与字节逐位不变(测试钉死)。真机 RSS 复测归收口票。
- **PulseCore 纯值层**:`JunkRules.swift` 规则表 15 条全局工具缓存(Xcode DerivedData / DeviceSupport(后缀模式一条覆盖五个 OS)/ Xcode 缓存 / 模拟器缓存 / SwiftPM / Homebrew / npm _cacache / _npx / pnpm store(两位置)/ CocoaPods / Gradle / JetBrains / VS Code(三目录)/ Cursor(两目录)/ Docker Desktop Data;路径与档位移植 purge-app MIT,文件头注明出处与逐条差异:三档收两档、JetBrains 整目录→先检查并点明 Local History、Docker 取 Data 子目录、文案中文重述)+ `JunkMatcher` 跑在扫描树(`SpaceNode.descendant(atPath:)`;空目录不列、部分扫描照列并标)。`CleanPlan.swift`:JunkSelection 默认全不勾 / CleanPlan 删前排除二次判定 / CleanRunner 回执逐项核对(漏报按失败)。`CleanHistory.swift`:迁移 `p4-cleaner-04-clean-history` 加 clean_run + clean_item(只加表,零单向门)+ CleanHistoryStore actor。`CleanExclusions.swift`:扫描侧(Walker.isExcluded)与删除侧(CleanPlan)**共用同一判定函数**,加入只收窄(覆盖去重)。
- **App 层**:CleanExclusionsStore(UserDefaults `cleanerExcludedPaths`,ProjectRootsStore 同款);LiveCleanTrashExecutor(NSWorkspace.recycle **逐项**调用——批量 error 分不清哪项失败;emptyTrash 协议履约,按钮与真机验证归 08);HistoryFeature.cleanHistory 与采样历史同库同队列(HistoryEngine.database 改 nonisolated);CleanerModel 删除管线(清单计算属性读 exclusions.paths → 设置页加排除即时反映;确认 → 执行 → 记历史 → 已回收路径不再列 → 勾选收敛;页头如实提示"本次已清理 N 项,重新扫描刷新数字");CleanerJunkViews(清单卡组分段 + 行借排行行配方 + TierChip + 右键排除/Finder + 动作条 + 460 定宽确认 sheet + 结果卡失败如实报 + 历史子页列表/明细);设置页「清理」排除管理;穿线 PulseApp → MainWindowGate → MainWindowView。
- **测试**:登记完整性(每条规则正例表 + 故意加无正例规则必红 + 正例表无过期 id)/ 似是而非 9 例目录不出现 / DeviceSupport 变体各成一单元 / 票面点名档位 / 空目录隐、部分扫描显 / 排除只收窄(⊆)/ 计划与清单同序 / spy 恰好收到计划路径 / 漏报按失败 / 历史往返 + 迁移幂等 / 排除判定分量级 + 吸收 / 模型端到端(内存库 + spy)/ 失败项留清单 / 历史缺席照删 / 右键排除即时 + 持久化 + 重扫不枚举。
- **顺手修**:进度条斜率 65 万 → 340 万;DESIGN.md 登记清单行 / TierChip / 动作条 / `{layout.sheet-width}` 460 / `{layout.sheet-list-max-height}` 220。
- **流程记档**:`.worktrees/p4-junk` 里 hosted 测试 runner 连续两次"hung before establishing connection"(无崩溃报告;Documents 病复发),按交接回退到 `/tmp/pulse-p4-junk`(`--detach` 同 commit)跑 check.sh 全绿;zsh 不分词 `$files` 让首次 swiftformat 批量修复静默无效(xargs 后正常)。
- **待用户目验**:①确认后文件真在 Finder 废纸篓且可恢复 ②清单 / 档位 chip / 动作条 / 确认 sheet / 结果卡 / 历史子页观感 ③设置页「清理」排除增删 ④右键排除后行消失。**待拍板**:整组勾选(见最终汇报摆的背景与优缺点)。

**2026-10-30 拍板 B 落地(feat/p4-group-select):整组勾选做**——组头三态 checkbox
(NSButton allowsMixedState,none/mixed 点击全勾、all 点击全清)**只吃组内「可安全清理」
档的项**,先检查项永不被组勾选带上、必须逐个手勾;组内无 safe 档项不画。
纯值层 `JunkSelection.GroupState / state(of:) / set(_:for:)`(批量设置只动传入候选),
模型 `CleanerModel.groupState(of:) / toggleGroup(_:)`,UI `GroupCheckBox`。测试 +3(核心
2:三态迁移 / 批量只动传入项;app 1:组勾选只带 safe、all 全清不碰组外勾、mixed 全勾)。
DESIGN.md 清单行 bullet 已补组头三态 checkbox 条目。勾选框观感(与行内 checkbox 同款、
mixed 虚线)归目验项 ②。
