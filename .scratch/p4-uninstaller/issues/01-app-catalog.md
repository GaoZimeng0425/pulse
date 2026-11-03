# 01: 应用清单域 + 「应用」子页

**What to build:** 清理页第 4 个子药丸「应用」。PulseCore 新增应用清单纯值域:枚举 /Applications(含 /Applications/Utilities)+ ~/Applications 的 .app,产出每行的名字、路径、bundle id、.app 实际占用、Apple 签名判定、brew 徽标、灰行态(无权限 / 先退出),按名排序,v1 无搜索。UI 行 = 图标 + 名字 + .app 实际占用 + brew 徽标;灰行标「无权限」或「先退出」,不提供退出 / 终止按钮。

**接缝(全部一期已落地):**
- .app 实际占用骑 `CleanBoundary` 元数据枚举(block 口径 + 克隆 / 硬链接去重,界面标口径)。
- 「先退出」判定 = 进程快照 `executablePath` 前缀命中 .app 路径(与 CleanActivity 同源输入;判定不缓存)。
- 「无权限」= 删除位(如 /Applications 需管理员)不可写。
- Apple 签名判定用 Security.framework 离线查(SecStaticCode 系,不跑 codesign 子进程);**首项先做本机实机探针**定实现,判定失败的 app 不进清单并记台账(「永不进清单」是硬要求,宁可少列)。
- brew 徽标 = 离线读 Caskroom 收据(/opt/homebrew 与 /usr/local 双候选),INSTALL_RECEIPT.json 的 uninstall_artifacts 对 app 名;**收据形状本机实测记档**;对不上宁可漏标不误标。
- 图标走 AppIconCache(预栅格化);清单进 tab 才枚举,无常驻采集。
- Info.plist(bundle id / 显示名)读取进 Live 侧,纯值域吃结构化输入。

**Blocked by:** 无(本组首票)

**Status:** done

- [x] 本机探针:SecStaticCode 判 Apple 签名的可行实现 + Caskroom 收据真实形状,结论记档进本票 Comments
- [x] 夹具测试:Apple 签名 app 不出现;判定失败的 app 不出现且台账有记录
- [x] 夹具测试:运行中 app 灰行「先退出」;不可写位置 app 灰行「无权限」
- [x] 夹具测试:收据命中 → brew 徽标;对不上 → 无徽标(漏标不误标)
- [x] .app 实际占用与空间地图同口径(去重生效),界面标口径
- [x] 子药丸「应用」注册 + 防漂移登记测试;行按名排序
- [x] Live 装配:进 tab 才扫、可刷新,退出 tab 无后台任务

## Comments

- 2026-11-03 探针记档(票面首项):
  - **签名**:SecStaticCode + requirement `anchor apple` 验证(Safari/Calculator=true;Bitwarden/DockDoor/CleanMyMac=-67050)。关键反例:CleanMyMac 老式 DigiCert 签名同样 **team=nil**——team id 不是判据,必须走 requirement 验证;验证器自身报错 = unverifiable 单列台账。
  - **收据**:brew 7.0.12 实测,每 cask 恰一份 `/opt/homebrew/Caskroom/<cask>/.metadata/INSTALL_RECEIPT.json`(旧版 .metadata/<version>/<hash>/ 层级已不存在);`uninstall_artifacts` 数组含 `{"app":["名字.app"]}`(徽标键)与 `{"zap":[{"trash":["~/Library/…"]}]}`(02 票残留路径来源,~ 已在解析时展开)。
  - `~/Applications` 实机有内容(Chrome Apps.localized 等 .localized 目录 + 散 app):v1 只枚举顶层 .app 后缀,.localized 目录不递归(spec 口径)。
- 2026-11-03 实施落地(3051c69,合 develop):PulseCore AppCatalog/CaskReceipt + Live LiveAppCatalogSource + UninstallModel + AppListSection;测试核心 17 例新增 + app 2 例防漂移,全量 1016 绿(/tmp 复跑,worktree hosted 挂死照旧回退)。brew chip 的 tooltip 已注明「卸载走 brew uninstall(03 票)」。
- 欠目验:清单与 Finder 互证、brew 徽标本机对拍(收 04 票清单)。
