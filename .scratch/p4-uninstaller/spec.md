# P4 二期 spec:应用卸载器

Status: ready-for-agent
来源:2026-11-01 grill 定案,决策全文移植自 `.scratch/p4-cleaner/spec.md`「二期:应用卸载器」节(该节为唯一决策出处,本文不新增决策);2026-11-03 用户拍板开工(同期挂起 p4-cleaner/06、08)。
词汇:GLOSSARY「清理」节(应用卸载 / 残留 / 彻底删除 / cask 收据);ADR-0008(白名单默认拒绝)、ADR-0009(不经 root)、ADR-0010(废纸篓是默认技术路径而非原则)原样适用。
参考:purge-app(MIT)算法与规则表可移植,搬码注明出处;Mole(GPL-3.0)只借思路。

## Problem Statement

一期清理器只认「目录垃圾」:能收走 DerivedData 与 node_modules,但用户想彻底送走一个 app(连同 ~/Library 里的残留)时,Pulse 仍无能为力,还得拖 Finder 或装 CleanMyMac。卸载的核心难题同一期:「敢删」——Apple 系统 app 绝不能碰,brew 装的绝不能绕过 brew 删文件,残留必须精确匹配而不是按名字广撒网。

## Solution

清理页第 4 个子药丸「应用」:/Applications(含 Utilities)+ ~/Applications 的 .app 清单,Apple 签名系统应用永不进清单;每行 = 图标 + 名字 + .app 实际占用 + brew 徽标;点行展开残留清单(默认不勾);卸载默认一律移废纸篓并复用一期确认清单弹窗,brew 应用改道 `brew uninstall --cask`;显式勾选「彻底删除」才走永久路径(brew 走 `--zap`),确认清单逐行标明不可恢复。

## 定案内容(照抄 p4-cleaner/spec.md 二期节)

- **入口与清单**:清理页第 4 个子药丸「应用」。清单 = /Applications(含 Utilities)+ ~/Applications 的 .app,按名排序,v1 无搜索;Apple 签名的系统应用永不进清单;无权限删除的灰行标「无权限」;正在运行的灰行标「先退出」,不提供退出 / 终止按钮。在用保护与清理器同款:删除前重查、判定不缓存。
- **行与交互**:图标 + 名字 + .app 实际占用 + brew 徽标;点行展开残留清单(每行 = 路径 + 实际占用,默认不勾);v1 单 app 逐个卸载,不做跨 app 多选;不做「最近使用时间」。
- **brew 侧**:徽标判定 = 离线读 Caskroom 收据(INSTALL_RECEIPT.json 的 uninstall_artifacts 对 app 名),对不上宁可漏标不误标。执行卸载时才调 `brew uninstall --cask`;brew 缺失 / 失败 = 行内红字原因 + 本次整体中止,绝不回退文件删除。非 brew 徽标的应用点卸载时,本机有 brew 则动作时刻跑一次交叉核对,发现归 brew 管即提示改道(可继续可取消)。brew 应用的残留候选优先取收据 zap 段声明的路径,未覆盖处落回通用位置清单。
- **删除执行**:默认 .app + 所选残留一律移废纸篓,复用清理器同款确认清单弹窗;「彻底删除」勾选(brew / 非 brew 统一,默认不勾、不记忆跨次):勾 = 永久删除(brew 走 `--zap`),确认清单逐行标「永久删除」+ 明示不可恢复(ADR-0010)。
- **残留候选位置**(键 = bundle id 与应用名,目录名全等才命中):Application Support / Caches / Preferences(`<bid>.plist`)/ Containers / Group Containers(后缀匹配,前缀为团队 id)/ Saved Application State / HTTPStorages / WebKit / Logs / Application Scripts;LaunchAgents 恒「先检查」档;PrivilegedHelperTools 不碰(root 域)。
- **清理历史**:沿用同表,去向新增「已卸载(brew,永久)」与「永久删除」。

## 一期复用接缝(全部已落地,p4-cleaner/01–05+07+10+11)

- `CleanBoundary`(清理系统边界协议):元数据批枚举 → .app 实际占用(block 口径 + 克隆 / 硬链接去重);移入废纸篓;进程活动问询。永久删除是二期新增能力,挂同一协议。
- `CleanPlan` 确认清单弹窗、`CleanActivity` 在用保护(进程快照 `executablePath` 前缀命中 = 「先退出」判定输入)、`CleanHistory` 落库(去向枚举扩展)、排除机制不适用于本域(右键排除是一期目录扫描口径)。
- 子药丸注册沿用清理页既有模式;图标走 AppIconCache(预栅格化先例)。

## Testing Decisions

- 夹具驱动只测外部行为(一期同款):清单域喂假边界 → 断言清单 / 灰行 / 徽标;残留引擎喂假 fs + 假收据 → 断言候选与档位;执行管线用 spy 断言「收到哪些路径 / 是否调了 brew」,绝不真删。
- 防漂移:子页注册、规则域、历史新去向各有登记完整性测试(p2-audit 教训)。
- 本机实测项:收据形状、签名判定可行性,进票 01 首项,结论记档。
- 稳态:卸载无常驻采集,收口票复测稳态与窗口指纹。

## Out of Scope

v1 无搜索、无跨 app 多选、无「最近使用时间」;PrivilegedHelperTools 恒不碰;iSurge 式 Homebrew 管理页不做;清理页(开发者垃圾)不加「彻底删除」——那里的永久路径仍是「废纸篓 → 清空废纸篓」两段式;自动 / 定时任何动作;经 root 帮手。

## 票组划分

01 应用清单域 + 「应用」子页 → 02 残留候选引擎 + 展开行 → 03 卸载执行(brew 改道 + 彻底删除 + 历史扩展) → 04 收口(稳态 / 防漂移 / 目验)。
