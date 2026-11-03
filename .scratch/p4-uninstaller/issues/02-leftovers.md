# 02: 残留候选引擎 + 展开行

**What to build:** 给清单里的每个 app 算残留候选清单。键 = bundle id 与应用名两把,**目录名全等才命中**(Group Containers 例外:后缀匹配,前缀为团队 id)。通用位置清单:Application Support / Caches / Preferences(`<bid>.plist`)/ Containers / Group Containers / Saved Application State / HTTPStorages / WebKit / Logs / Application Scripts;LaunchAgents 恒「先检查」档;PrivilegedHelperTools 永不出现(root 域)。brew 应用残留候选优先取收据 zap 段声明的路径,未覆盖处落回通用位置清单。每行残留 = 路径 + 实际占用,默认不勾。UI:点 app 行展开残留清单。

**接缝:** 实际占用骑 `CleanBoundary` 元数据枚举(同口径去重);收据 zap 段读取沿用票 01 的收据读取器;候选位置判定纯值化(PulseCore,喂假 fs 夹具);Info.plist 读不到 bundle id 的 app → 残留清单如实为空并标注「无 bundle id」,不拿应用名硬猜 Group Containers。

**Blocked by:** 01(清单形状与收据读取器)

**Status:** ready-for-agent

- [ ] 夹具测试:bundle id / 应用名两把键全等命中与不命中;目录名前缀相似不误中
- [ ] 夹具测试:Group Containers 后缀匹配(团队 id 前缀);Preferences 只认 `<bid>.plist`
- [ ] 夹具测试:LaunchAgents 候选恒「先检查」;PrivilegedHelperTools 永不出现(测试断言)
- [ ] 夹具测试:收据 zap 段路径优先并入、通用位置补未覆盖处(合成收据)
- [ ] 残留行默认不勾;实际占用与口径标注一致;展开行 UI
- [ ] 无 bundle id 的 app:残留为空 + 标注,不误猜
