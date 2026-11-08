# 02: 已装全集采集 + 接线 + 第三组 UI + 地图/历史

**What to build:** Live 侧把检测核心接进清理页。

1. **已装 bundle id 全集采集**(Live,未过滤):/Applications、/System/Applications、~/Applications、/opt/homebrew/Caskroom、/usr/local/Caskroom、Setapp 目录 find `.app`(maxdepth 3)读 `Info.plist` 的 `CFBundleIdentifier`;**plist 解析失败 = 采集失败 → fail-closed 整组不出**(Mole 纪律;plist 合法但无 id 的 app 跳过不失败——没有 id 就不拥有 id 命名的残留)。全集并入 `NSWorkspace.runningApplications` 的 bundle id。扫描时采集一次,与扫描结果同缓存。
2. CleanerModel 接线:computeCandidates 加孤儿来源;CandidatesKey 不变(全集随 phase 走);组序 junk|map→(组内)工具缓存/项目产物/**卸载残留**。
3. UI:第三组渲染走既有管道(projectName 分组大卡自动生效);显示名=尾段、副标全 id+路径(候选 subtitle 既有逻辑复用,`JunkCandidate.title` = 显示名?——票 01 的 title 取尾段、path 全路径,行副标显路径即区分);组头同款;页头注记「含卸载残留检测」。
4. 地图「这块能清」角标表加 `.uninstallLeftovers`;轻桥跳转复用。
5. 历史行:ruleID `app-orphan` 已由票 01 产出,历史页/找回零改动;确认 sheet 走既有。
6. 防漂移:组序 + 组名结构性断言。

**Status:** done(2026-11-08,分支 feat/orphan-ui)

- [x] 全集采集(含运行中合并 + fail-closed)
- [x] 接线 + 组序 + 页头注记
- [x] 第三组渲染 + 大卡分组(复用验证)
- [x] 地图角标 + 轻桥
- [x] 防漂移断言

## Comments

**2026-11-08 实施记录(偏离票面三处,均往保守走):**

1. **全集来源 = 并集**(票面「6 目录 find」与 spec §4「全卷扫描树找 .app」不一致,两者
   各漏一块,取并集):扫描树内全部 bundle(.app/.appex/.xpc,含嵌套 helper——Downloads
   里直接跑的 app、DerivedData 里自研 app 都算在)∪ 标准目录 Live 补扫(maxdepth 3)∪
   运行中。标准目录比票面多收 Mole 根表里的 `~/Library/Application Support/Setapp/Applications`
   与 `/Library/Input Methods` + `~/Library/Input Methods`(输入法不住 /Applications,
   漏了会把搜狗 / 微信输入法缓存判孤儿)。plist 直读(PropertyListSerialization),不走
   `Bundle(url:)`——后者进程级缓存同路径永不重读,且分不清「没有 plist」与「plist 坏了」。
   无 plist 的 bundle(iOS 包装壳外层)跳过不失败;扫描取消 = 半棵树 → fail-closed。
   缓存装载路径**现采**全集(树用缓存快照,标准目录 / 运行中取此刻),不落盘一份旧全集。
2. **分组键改为完整 bundle id**(修正票 01 的尾段分组):尾段只做显示名,否则
   `com.figma.Desktop` 与 `com.foo.Desktop` 会并进一张「Desktop」卡。
3. **与规则表重叠的孤儿让位**(真案:规则表 `Library/Caches/org.swift.swiftpm` 是 CLI
   缓存、无 .app,孤儿检测也会报——同路径两张卡、勾一联动二、确认清单重复)。路径相等
   或互为祖孙即让位(`OrphanLeftoverDetector.excludingOverlaps`)。

**顺手修**:项目大卡头排「N 天前动过」恒显示「今天动过」(旧式 `timeIntervalSinceNow`
对过去时刻为负被 `<= 0` 吞掉,上一轮改版引入)——抽 `JunkAgeText` 并加回归用例。

**测试**:核心 +12(全集 9 / 孤儿 +3:同尾段分卡、规则表让位、祖孙重叠;组序断言
扩为全量组序 + 组名 + groupsByOwner 登记面);app 侧 `CleanerOrphanWiringTests` 9 例
(采集器注入,零真盘)。全量套件照旧等用户发起。
