# p5-cleaner:清理功能深化 · 一期(孤儿残留 + 删前复核)

Status: ready-for-agent(2026-11-08 grill 共识 16 项 + 3 顺延默认全锁定)

## Problem Statement

清理页目前只认「开发者垃圾」(工具缓存 + 项目产物);用户要清的另一半——**过去卸载没删干净的 ~/Library 尸体**——没人管。卸载器只在「主动卸载某 app」时定向探测残留,历史欠账扫不到。另:删除执行缺「扫描后未被修改」复核(purrge-3,三家参考都有同款)。

## 产品主线

用户点「扫描整台 Mac」→ 结果里除工具缓存/项目产物外,多一组「**卸载残留**」:按 app 分大卡(bundle id 尾段显示名),子项缩进,精确匹配 + 30 天未动 = 可安全清理;勾选 → 移废纸篓(与其他组同一闸门)。所有清理(含老组)删前多一道「扫描后未修改」复核。

## 定案(grill 2026-11-08,三轮 16 项)

### 检测范围
1. **5 域**:`~/Library/Caches`、`~/Library/Logs`、`~/Library/Saved Application State`、`~/Library/WebKit`、`~/Library/HTTPStorages`;只吃反域名前缀命名目录(`com.* org.* net.* io.*` 开头;Saved Application State 再剥 `.savedState` 后缀)。
2. **五条红线 v1 不碰**:Containers / Group Containers / LaunchAgents / Application Scripts / PrivilegedHelperTools(Mole CRITICAL 教训 + Pearcleaner Group Containers 亦排除)。
3. **内置敏感名单**(永不判孤儿、不给「先检查」):1Password/Keychain/Bitwarden/LastPass/KeePass/ssh/gpg/gnupg 类目录名;PulseCore 常量单出处。

### 判定管线(六闸,顺序即廉价优先)
4. **已装权威源 = 全卷扫描树定位 `.app` → 读 Info.plist 的未过滤 bundle id 全集**(含 Apple 系统应用、/System/Applications、Caskroom、Setapp、~/Applications);**树不可用 = fail-closed 整组不出**(Mole「不完整的清单无权判孤儿」)。AppCatalog(过滤后)不参与判孤儿——它隐藏 Apple 签名 app,用它会把 com.apple.* 全判孤儿(设计期识破的陷阱)。
5. `com.apple.*` 等系统前缀 = **红线**永不判孤儿(不是档位)。
6. 运行中 app(`NSWorkspace.runningApplications` bundle id)并入已装全集(防「app 在跑但 .app 挪走」)。
7. 时间闸:树上该目录 `newestChangeEpoch`(目录树内任何文件最新变动,与项目年龄同语义同出处)≥ **30 天**才可判;30 天内 = 「先检查」。
8. 随「扫描整台 Mac」出结果,与既有缓存复用;页头注记含卸载残留检测。

### 档位
9. 两态:**精确 bundle id 匹配 + 30 天未动 =「可安全清理」;30 天内动过 =「先检查」**。非反域名命名 v1 不列出(无模糊匹配)。

### UI
10. 垃圾子页第三组「**卸载残留**」,排在「项目产物」之后。
11. 组内按 bundle id 分 **app 大卡**(显示名 = bundle id 尾段,副标全 id + 路径),子项缩进裸行——同项目产物形态。
12. 勾选两层口径同项目卡:状态反映全部非在用子项;动作只全选安全档。
13. 无结果组不出现(同现有空态规则)。
14. 空间地图「这块能清」角标认孤儿组;轻桥跳转定位复用。

### 删除与历史
15. **删前复核(全清理统一,执行层一道)**:目标仍存在 + 目录自身 mtime 与扫描快照一致;不一致 = 该项跳过并如实报「扫描后有变动」。在用重查之外的独立第二道闸。
16. 右键排除对孤儿项生效;历史 ruleID = `app-orphan`,去向复用 `.recycled`(零新枚举,历史页/找回/类型标记白捡)。

### 顺延默认(既有模式顺延,未单独拍)
组头同款(全选安全项 / 大小|新旧 seg);大小 = 实际占用口径;删除 = 移废纸篓。

## 参考与纪律
- Mole(tw93/Mole,GPL-3.0,本地 clone):机制提取(域清单/六闸判定/删前 inode 快照/Containers stub 例外),**零搬码**。
- Pearcleaner(alienator88/Pearcleaner,Apache-2.0+Commons Clause,gh api 实读):22 宽域反例 + Group Containers 排除互证;零搬码。
- purrge(PolyForm Noncommercial):档位体系互证 + 删前复核思路;零搬码。
- 我方架构红利:全卷扫描树做已装权威(免疫 Mole 的 Spotlight 超时假阳性 #1584)。

## Testing Decisions
- 检测核心进 PulseCore 纯值(`swift test`,零真盘):夹具树 + 全集各态(命中/未命中/30 天界/系统前缀/敏感名单/运行中/域红线/.savedState 剥尾)。
- 删前复核:夹具执行器测「变动即跳过 + 如实报」。
- UI 防漂移:组序 + 组名入册(既有结构性断言套路)。
- 全量 check 用户发起(纪律不变)。

## Tickets
- `issues/01-orphan-core.md` — PulseCore 孤儿检测核心(域表/六闸/档位/敏感名单/候选产出 + 夹具测试)
- `issues/02-orphan-ui.md` — Live 已装全集采集 + 接线(组序/缓存)+ 第三组大卡 UI + 地图角标 + 历史行
- `issues/03-predelete-verify.md` — 删前复核(全清理统一,执行层)+ 收口 check

## Out of Scope(记录不实施)
生态缓存扩充(purge-app 剩余规则)/安装包与大文件/AI 开发垃圾分组(p4-cleaner/06 续)/低空间告警闭环(purrge-1)/Containers stub 清理/模糊匹配。
