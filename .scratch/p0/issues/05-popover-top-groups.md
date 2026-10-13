# 05: 弹窗 Top-5 真组卡

**What to build:** 弹窗从静态假数据切到真归组:每轮采样后经归组引擎得出组列表,弹窗按组 CPU% 降序显示 Top-5 组卡——组名 + App 图标(bundle 组读应用图标,项目组/兜底类用符号图)、组 CPU%(单核累加口径)、内存、"N 进程"副标题。系统组参与排名;孤儿进程类橙色高亮。无 sparkline(P0 不做空图)。这是验收场景"一眼看到 octok-client 445%"的首次真实呈现。

**Blocked by:** 03, 04。

**Status:** done

- [x] 弹窗显示真实 Top-5 组,排序随负载变化实时刷新
- [x] 组卡四要素齐全:组名/图标、组 CPU%、内存、进程数
- [x] 开发中项目(如正在跑测试/编译)以"项目名 @ worktree"组名出现,组 CPU% 可见 400%+ 级别读数
- [x] 孤儿进程组卡呈橙色系;系统/后台服务类有可辨识的类别标记
- [x] bundle 组显示真实应用图标
- [x] 无组可显示(极端空载)时不出现坏 UI

## Comments

## Comments

- 工单完成(p0/05):管线收敛为 `Sampler` 每轮交付 `SamplingUpdate`(快照+差分)→ `GroupingPipeline`(纯值类型状态机:出生登记 → 引擎归组 → 截 Top-5)→ `SystemMonitor.topGroups`(@Observable),假卡与"静态假数据"页脚已删。全管线合成测试:门禁树两轮采样归出"octok-client @ worktree" 465%(400%+ 读数断言"465%")居首、系统组参榜;真机冒烟(823 进程)全量组降序、系统组在榜、Top-5 截取正确。bundle 显示名注入 `BundleDisplayNameReader`(CFBundleName,按路径缓存);孤儿卡橙色调,类别符号互异有单测。
- 备注:真机上看到"项目名 @ worktree"组需要配置项目根——用户入口(设置窗 + UserDefaults 持久化)按分工在工单 07;`SystemMonitor(projectRoots:)` 已留注入位,07 只需接上。系统组"参与排名"= 在榜但可能低于 Top-5 截线(launchd 常年近 0%),冒烟断言按此口径。像素级视觉验收归工单 09(SwiftUI 预览已就位)。
