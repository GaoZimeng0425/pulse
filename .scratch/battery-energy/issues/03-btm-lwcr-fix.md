# 03: 电耗助手换身份号 helper3——BTM 沉积条目 LWCR 指纹白名单为空,关-开循环永远无效

**What to build:** 特权助手登记从 `com.gaozimeng.pulse.helper2` 换到
`com.gaozimeng.pulse.helper3`(全新 BTM 条目 = 干净批准链,批准时当前
cdhash 才会写入 Launch Constraint 放行名单);app 侧在开关操作时幂等注销
helper2 沉积死条目。helper 二进制与签名不动(cdhash 不变,不触发重批守卫)。

**背景(2026-11-23 定谳,证据链全档):** 用户报「权限开-关无数次就是不行」。
探针三步定谳:① `sfltool dumpbtm`(免 root 可跑)显示 helper2 条目
`[enabled, allowed]` 但 `Last Use: 2026-11-01`、Generation 84,父条目
Generation 8590458880 沉积;② job 其实躺在 launchd(`type = Submitted,
state = not running`),`launchctl print` 抓到 **LWCR `cdhash $in` 白名单
为空数组** + `needs LWCR update` 挂着没人更新;③ 26h launchd 日志实录
用户 11:13 最近一次关-开循环:`removing job (smd)` → `Submit job
succeeded` → **15ms 后 `OS_REASON_CODESIGNING | Launch Constraint
Violation (Constraint not matched)` → `removing service since it exited
with consistent failure`**。即:批准与开关全是真的,死因是放行名单为空,
拉起必被拒杀,用户侧任何操作都补不进名单。装机 helper 签名验证正常
(Apple Development,Team=YHT8FN67G3,cdhash=15ee5021…)。
修法选型:换身份号(10-27 helper→helper2 同款手术,当日复活)优于
`sfltool resetbtm`(全机 134 项后台项重批,大锤)——用户 11-23 拍板换身份号。

**Status:** done(2026-11-23,装机后用户批准一次即闭环)

- [x] 新增 `Packages/PulseHelper/com.gaozimeng.pulse.helper3.plist`
      (Label=helper3,其余继承 helper2:相对 BundleProgram + RunAtLoad;
      注释带全定谳与历史口径)
- [x] `EnergyImpactFeature.swift`:三处 plistName → helper3;新增幂等
      `unregisterLegacyHelper2()`(setInstalled / reRegisterAndOpenApproval
      开头调用);helper2.plist 保留随 bundle 分发(注销时按此路径解析)
- [x] `build.sh`:追加 cp helper3.plist(helper2 的 cp 保留)
- [x] check 全绿 → 合并装机

**Out of scope:** helper 二进制/签名(不动);helper 第一代 plist 的
bundle 清理(无 register 关系,纯遗留文件,不引入变量);BTM 库里
helper2 注销失败时的观感残留(全新条目不受影响)。

## Comments

- 落地验证(装机后):电池页引导行 → 点它 → 设置开关打开(自动跳系统
  设置批准页并高亮新条目)→ 批准一次 → 1 分钟内「耗电排行 · 全部应用」
  出数据;`ps` 可见 pulse-helper 进程,`launchctl print
  system/com.gaozimeng.pulse.helper3` 应为 running 且 LWCR 白名单非空。
- 排障手法沉淀:`sfltool dumpbtm` 免 root 可跑,是 BTM 沉积第一现场;
  「开关无效」类问题先 `launchctl print` 看 LWCR 块,白名单空 = 条目
  沉积,换身份号是唯一不动系统的活路。
