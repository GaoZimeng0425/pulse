# 01: 孤儿检测核心(PulseCore 纯值)

**What to build:** spec §检测范围/判定管线 的纯值实现,零真盘可测。

1. `OrphanScanDomain`:5 域表(路径 + 反域名前缀判定 + `.savedState` 剥尾);红线域不进表(不存在即不扫)。
2. `OrphanLeftoverDetector.detect(tree:home:installedBundleIDs:runningBundleIDs:excludedPathPrefixes:now:)`:
   树上取各域子目录 → 六闸(排除前缀 → 敏感名单 → 已装全集(含运行中)→ 系统前缀红线 → 反域名命名 → 30 天 newestChangeEpoch)→ 产出 `JunkCandidate`:
   - `group = .uninstallLeftovers`(JunkGroup 新 case,title「卸载残留」,排序在 projectArtifacts 后)
   - `ruleID = "app-orphan"`;`projectName = bundle id 尾段`(大卡分组复用 projectName 管道)
   - `tier`:30 天未动 = .safe;30 天内 = .checkFirst;`symbolName = "app.dashed"`
   - `bytes/newestChangeEpoch/isPartial` 照树口径
3. 系统前缀红线常量(`com.apple.*` 等)+ 敏感名单常量(1Password/Keychain/Bitwarden/LastPass/KeePass/ssh/gpg/gnupg),单出处。
4. 夹具测试:命中/全集命中不列/30 天界两侧/系统前缀/敏感名单/运行中保护/.savedState 剥尾匹配/非反域名不列/五红线域不存在即无输出/排除前缀生效/树空 fail-closed 由调用方负责(核心函数自身输出空)。

**Status:** done

- [x] 域表 + 六闸检测器 + 常量
- [x] JunkGroup 新 case(组名/组序)+ 候选产出
- [x] 夹具测试全绿(16 例:六闸逐闸/跨域聚合/.savedState 剥尾/零字节纪律/子树年龄/显示名/域表登记)

## Comments

- 2026-11-08 实施:OrphanLeftovers.swift(检测器)+ JunkGroup.uninstallLeftovers(殿后)。
- 首版敏感名单漏了 1Password 旧 id `com.agilebits.onepassword`(不含数字「1」),
  testSensitiveNamesAreRedline 当场揭出 → 名单补 onepassword/agilebits 双写。

- [ ] 域表 + 六闸检测器 + 常量
- [ ] JunkGroup 新 case(组名/组序)+ 候选产出
- [ ] 夹具测试全绿(新增用例 ≥ 10)
