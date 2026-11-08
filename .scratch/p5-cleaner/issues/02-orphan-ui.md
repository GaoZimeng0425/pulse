# 02: 已装全集采集 + 接线 + 第三组 UI + 地图/历史

**What to build:** Live 侧把检测核心接进清理页。

1. **已装 bundle id 全集采集**(Live,未过滤):/Applications、/System/Applications、~/Applications、/opt/homebrew/Caskroom、/usr/local/Caskroom、Setapp 目录 find `.app`(maxdepth 3)读 `Info.plist` 的 `CFBundleIdentifier`;**plist 解析失败 = 采集失败 → fail-closed 整组不出**(Mole 纪律;plist 合法但无 id 的 app 跳过不失败——没有 id 就不拥有 id 命名的残留)。全集并入 `NSWorkspace.runningApplications` 的 bundle id。扫描时采集一次,与扫描结果同缓存。
2. CleanerModel 接线:computeCandidates 加孤儿来源;CandidatesKey 不变(全集随 phase 走);组序 junk|map→(组内)工具缓存/项目产物/**卸载残留**。
3. UI:第三组渲染走既有管道(projectName 分组大卡自动生效);显示名=尾段、副标全 id+路径(候选 subtitle 既有逻辑复用,`JunkCandidate.title` = 显示名?——票 01 的 title 取尾段、path 全路径,行副标显路径即区分);组头同款;页头注记「含卸载残留检测」。
4. 地图「这块能清」角标表加 `.uninstallLeftovers`;轻桥跳转复用。
5. 历史行:ruleID `app-orphan` 已由票 01 产出,历史页/找回零改动;确认 sheet 走既有。
6. 防漂移:组序 + 组名结构性断言。

**Status:** ready-for-agent

- [ ] 全集采集(含运行中合并 + fail-closed)
- [ ] 接线 + 组序 + 页头注记
- [ ] 第三组渲染 + 大卡分组(复用验证)
- [ ] 地图角标 + 轻桥
- [ ] 防漂移断言
