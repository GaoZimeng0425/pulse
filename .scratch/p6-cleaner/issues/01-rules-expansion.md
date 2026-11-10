# p6-cleaner/01:规则域扩充(浏览器 / 应用缓存知识库 + 开发工具补行)

Status: ready-for-agent

## 目标

JunkGroup 扩六组 + 新规则首批落地,全部走既有白名单机制——未识别不显示不碰(ADR-0008),组名与组序按 spec 定案 8。

## 范围

1. `JunkGroup` 新增 `browserCache`(浏览器)/ `appCache`(应用缓存)/ `aiModels`(AI 模型)三 case;CaseIterable 序 = 开发工具 → 浏览器 → 应用缓存 → 项目产物 → AI 模型 → 卸载残留;`groupsByOwner` 穷举表态(三新组 false)。全部穷举 switch 编译器强制表态,漏一处编不过。
2. 新文件 `Packages/PulseCore/Sources/PulseCore/AppCacheCatalog.swift`:知识库纯值表——缓存目录名(保留规范大小写,可多别名)→ 标题 / 档位 / 中文 rationale / 组(浏览器 or 应用缓存)。首批 = 浏览器全家 + 常见 app 约 30 条(本机在场与高频优先);移植自 purge-app `explanations.json`(MIT,`source` 注明),文案按 Pulse 两档口径中文重写(不是逐字翻译);**认不出的目录不列(v1,spec 定案 10)**。
3. `JunkRuleTable.builtin` 重组 = 开发工具规则(现有 + 补行)+ 目录规则(由 AppCacheCatalog 生成,id 前缀 `browser.` / `appcache.`,pattern = `Library/Caches/<目录名>` 字面匹配);匹配 / 去重 / UI / 历史 / 排除 / 孤儿域收窄全部沿用既有管线,零新机制。
4. 开发工具补行(spec 定案 12,全 safe 除注明):`~/.cargo/{registry,git}`、`~/.cache/uv`、`~/go/pkg/mod` + `~/Library/Caches/go-build`、`~/.m2/repository`、`~/Library/Caches/pnpm`(2026-11-09 真案漏网)、Xcode Archives(先检查)、`~/Library/Developer/XCTestDevices`(先检查)、Corepack / Yarn / Deno / Bun 常用位、`~/Library/Caches/{electron,electron-builder,node-gyp}`。
5. 登记完整性:`positiveExamples` 每条新规则补正例(路径可从 pattern 推导,允许脚本生成后人工粘入);`lookalikes` 补反例(非知识库名的 Caches 一级目录、`-old` 变体);受影响的既有断言同步改(排除收窄计数、组内排序跨组断言);孤儿域去重接缝确认新规则自动收窄(p5-cleaner/02 同款,`Library/Caches/org.swift.swiftpm` 真案)。

## 验收

- 每条新规则:正例命中 + rationale 非空 + source 注明出处;未识别 Caches 目录绝不出现。
- 夹具目录名用本机真案:Arc / Dia / CloudKit / pnpm / electron 等。
- 组序 = spec 定案 8;空组(AI 模型在 02 前)不出段。

## 测试

PulseCore `swift test` 全绿(合成夹具零真盘);合并前 `sh scripts/check.sh` 全绿。

## Comments
