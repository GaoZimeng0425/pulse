# p7-cleaner/10:规则表搬运二——全局缓存 + 项目产物规则补差

Status: ready-for-agent(2026-11-26 立)
Blocked by: 无(可立即开始)

## 目标

把 purge-app 的全局工具缓存规则(上次核实约 56 条)与项目产物规则(约 47 条)里我们还没有的部分搬进来:每条带档位、重建说明、出处。改之前:开发工具规则 32 条、项目产物 9 种;改之后:上游有的我们都有,「要花真实时间重建」的那些只进「先检查」。

## 范围

1. 全局缓存:逐条对照现有开发工具规则,缺的补;同路径合并;档位对齐上游——重建要花真实时间的(模拟器重新导入、归档等)一律「先检查」,永不自动勾。
2. 项目产物规则补差:上游有而我们没有的目录种类,以及「根标记 / 拒绝条件 / 重建说明」三个字段,补进现有规则。**本票只做上游表里有的**;来源是对齐对象的那部分归 11 票。
3. 「在场才列」纪律照旧:不在本机的规则照登记、不出现。
4. 登记完整性与反例同步;脚本批量改文件时逐处断言锚点。
5. 与 09 票的边界:本票不碰应用缓存知识库。

## 验收

- [ ] 每条新规则:正例命中、档位正确、说明与重建说明非空、出处注明
- [ ] 夹具:上游标「要花时间重建」的条目全在「先检查」
- [ ] 夹具:某条规则的位置不在夹具里 → 规则已登记但不产出候选
- [ ] 目验:开发工具组与项目产物组条目变多

## 测试

接缝 1;先例:规则表登记完整性用例、项目产物规则用例。全量检查与真机验证由用户发起。

## 依据与纪律

spec `p7-cleaner/spec.md`;GLOSSARY「安全白名单」「项目产物」「安全档」。上游许可 MIT,可移植,逐条注明出处。

## Comments

**2026-11-28 票 09 交接(上游说明库 ceacaf8 逐条对账后,归本票的部分;未动本票正文)**

- 上游说明库里交给本票的:**带目录名的 83 条,加没登记目录名的 51 条**。逐条清单(上游 key、档位、原名)在票 09 的 Comments「交接」一节;机器可读的版本是 `Packages/PulseCore/Tests/PulseCoreTests/AppCacheCatalogPortLedgerTests.swift` 搬运账本里下落为 `.ticket10` 的行——本票搬一条,就把那一行的下落改成 `.rule("<规则 id>")`,账本测试会盯着。
- **本机在场、值得先看**:`ms-playwright`(上游 medium;本机 572 MB,清了测试会失败,要重新 `npx playwright install`)、`bun-cache`(本机 `bun` 47 MB)、`typescript-type-cache`、`cypress-cache`、`mise-cache`、`pre-commit-cache`、`puppeteer-browsers`。另:本机 `pulse-swiftpm`(399 MB)是 Pulse 自己的 SwiftPM 构建缓存,上游表里没有,也归开发工具规则。
- **现有规则里档位比上游松的两处**(p6 的决定,上游 medium → 我们「可安全清理」;本票范围 1「档位对齐上游」时要表态):`gradle.caches`(`.gradle/caches`;上游 `gradle-global-cache` medium)、`maven.repository`(`.m2/repository`;上游 `maven` medium)。账本里这两条上游条目的下落因此记成「交给票 10」,没记成「已由现有规则担保」。
- **先读上游的二级闸门再搬**:`DeletionSafetyPolicy.isOfferedForCleanup` 有一串动态拒绝(Playwright 构建在用、CLI 版本在用、旧工具版本、链接竞态、Go 模块缓存的形状),`SafetyTierList` 有按后缀 / 形状的规则(`.shipit`、Chromium 形状、`-updater/pending`)。票 09 的教训:说明表 ≠ 会列出的东西。
- **手法**:条目与账本行由脚本从上游 JSON 生成,写出前逐名对照原件(票 09 的自检抓到一处手抄错字)。上游的浅克隆在 `/tmp/purge-app-src-09/repo`(临时,可能已清;提交 ceacaf8)。
