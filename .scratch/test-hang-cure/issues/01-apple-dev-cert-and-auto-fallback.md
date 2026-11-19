# test-hang-cure/01 hosted 测试挂死根治:Apple 开发证书 + 自动退路

Status: ready-for-agent
Type: task

## 背景

`.worktrees/<slug>` 里 app 侧 hosted 测试间歇挂死("hung before establishing
connection",6 分钟超时),同码 /tmp 全绿——病史与 11-13 根因查证见记忆/票档。
2026-11-18 双挂复发(负载 60+,agent-tab/12 实施夜),用户要求根治「撞墙→人工
换 /tmp」循环。

## 根因与决策链(2026-11-19,统一日志实证)

1. 挂起 = 宿主卡在 AMFI 代码签名准入:amfid 判 -423(adhoc/未知链,常态噪音)
   → syspolicyd 评估 → 放行决策不来 → 宿主零指令饿死。**不是权限拒绝,是
   安检无应答**;开发者模式已开仍复发(高负载下 syspolicyd 串行队列卡)。
2. **换 keychain 自签救不了**:统一日志实证 Release 版(`Pulse Local Code
   Signing` 自签身份)每次启动同样吃 -423——自签链对 AMFI 同为「未知链」。
3. **Apple 开发证书是唯一绕开链**:证书链到 Apple Root CA(系统信任)→
   AMFI 直接验证通过,不进 syspolicyd 请示。免费 Apple ID 即可(本地开发
   签名不需要付费 Developer ID——那是分发用的)。

## 改动

1. **Debug/测试构建换 Apple 开发证书**(project.yml:Debug config +
   PulseTests target `CODE_SIGN_IDENTITY: Apple Development` +
   `DEVELOPMENT_TEAM`);Release/build.sh 自签语义不动。证书由
   `xcodebuild build-for-testing -allowProvisioningUpdates` 无头铸造
   (Apple ID 需已在 Xcode 登录)。
2. **test.sh 双挂自动退路**:双挂 → 证据拷 `/tmp/pulse-hang-evidence/` →
   工作区干净才自动建 `/tmp/pulse-hosted-fallback` 续跑(同 `--only` 参),
   成功自动清树;`PULSE_TEST_FALLBACK=1` 防递归;失败留树排查。
3. AGENTS.md 两处成文规矩同步(分支回退条款、Debug 签名条款)。

## 验收

- [x] 宿主签名链:`Apple Development → Apple WWDR CA → Apple Root CA`
- [x] 决定性对照:昨天挂死的同位置(.worktrees 下)跑 hosted 测试绿,且
      **测试窗口内 amfid 对宿主零判定**(不再进评估链;对照:昨天同宿主
      -423 + 6 分钟挂死)
- [x] 证书无头铸造成功(xcodebuild -allowProvisioningUpdates)
- [ ] 全量门禁 + 合并(实施中)
- [ ] 观察期:后续多次 check.sh 零挂起(预期证书断链后不再发生)

## Comments

- 2026-11-19 立票即实施。用户问诊链:是否权限问题 → 三种签名差异 →
  「换签名方式」判断正确但只有 Apple 证书有效(自签被日志实证否定)。
  用户在 Xcode 登录 Apple ID 后由 xcodebuild 无头完成铸造,零手工。
