# P0:菜单栏"App 视角"监视器(采样 + 三层归组 + Top-5 弹窗)

Status: done

## Problem Statement

我的 Mac 经常莫名变卡——load 52,打开活动监视器只能看到约一千行进程列表:一百个 Google Chrome Helper、一串面目模糊的 rustc/node 进程、一个说不清来路的 OrbStack。它回答不了我真正的问题:**到底是什么在占用我的 CPU**。真相往往是"某项目在跑质量门禁 + 某个 AI 会话拉起的编译测试 + 一个遗忘三天的常驻进程",但这些因果关系在进程列表里完全不可见。

## Solution

Pulse:一个菜单栏常驻的"App 视角"系统监视器。菜单栏显示系统 CPU 负载(吃紧变红);点开弹窗看到的是 Top-5 **组**而非进程——千行进程被三层归组(App 归属 → 父链上溯 → 项目归因)折叠成"octok-client @ worktree 445%"这样的可读答案。每组可下钻到进程明细(cwd、完整 argv、启动时长、父链面包屑),并可带确认地 kill 单进程或整组。全程本地,零网络。

## User Stories

1. 作为 Mac 用户,我想在菜单栏一眼看到系统 CPU 负载(0–100% 总产能口径),这样不打开任何窗口就知道机器是否吃紧。
2. 作为 Mac 用户,我想让菜单栏数字在系统 CPU 负载超过 70% 时变红,这样平时不用盯,变色才看。
3. 作为 Mac 用户,我点击菜单栏数字能打开弹窗,这样需要时能立即下钻。
4. 作为被 CPU 占用困扰的用户,我想看到 Top-5 组而不是进程列表,这样"什么在吃 CPU"一眼有答案。
5. 作为被 CPU 占用困扰的用户,我想每组显示组名、组 CPU%、内存、进程数,这样不用自己心算汇总。
6. 作为多 Helper 应用的用户,我想让 Helper/Renderer/XPC 子进程自动跟随宿主 App 归组,这样每个应用只占一行。
7. 作为 AI 会话的用户,我想让 rustc ← cargo ← node ← ZCode 这样的进程链归组到拉起它的应用,这样 agent 拉起的编译测试不再是一串陌生进程。
8. 作为多项目开发者,我想看到"octok-client @ skill-manage-read-and-index"这样的项目组,这样知道是哪个项目在烧 CPU。
9. 作为多项目开发者,我想在设置窗里增删项目根目录,这样项目归因跟着我的实际工作目录走。
10. 作为多 worktree 用户,我想让 `.worktrees/<name>` 自动识别为"项目名 @ worktree",这样并行分支各自成组、互不混淆。
11. 作为排障用户,我想点击组卡展开组内进程(按 CPU 降序平铺),这样能看到组里具体是谁在干活。
12. 作为排障用户,我想点开进程看到它的 cwd 和完整 argv,这样能确定它到底在为哪个项目跑什么命令。
13. 作为排障用户,我想看到进程的启动时长("已 25 分钟"),这样能一眼识别"常驻 3 天"的遗忘进程。
14. 作为排障用户,我想看到父链面包屑("rustc ← cargo ← node ← ZCode"),这样理解进程是被谁、经由什么拉起来的。
15. 作为发现问题的用户,我想带确认地 kill 单个进程,这样精确处理肇事者。
16. 作为发现问题的用户,我想带确认地 kill 整组,这样一次清掉整个失控的 dev 会话。
17. 作为排障用户,我想孤儿进程用橙色高亮,这样"没有归属的东西"立刻显眼——它往往正是问题所在。
18. 作为排障用户,我想所有进程最终落进系统 / 后台服务 / 孤儿三类兜底,这样榜单完整、没有漏网之鱼。
19. 作为菜单栏常驻工具的用户,我想让 Pulse 常驻内存 < 30MB、合盖采样开销 ≈ 0.1% 单核,这样监控本身不成为负担。
20. 作为笔记本用户,我想弹窗关闭时 5s 采样、打开时 1s,这样平时省电、看的时候流畅。
21. 作为重启电脑的用户,我想活着的进程仍能实时父链上溯归组,这样即使出生登记(内存版)丢失,功能基本完整。
22. 作为隐私敏感的公司机用户,我想所有数据留在本机、应用零网络请求,这样无合规顾虑。

## Implementation Decisions

- **工程**:Xcode SwiftUI App 项目,App 名 Pulse,bundle id `com.gaozimeng.pulse`,最低 macOS 26,`LSUIElement`,不开 App Sandbox(ADR-0002),本地 ad-hoc 签名。技术栈选型见 ADR-0001。
- **唯一测试接缝:`ProcessSource` 协议**(OS 边界)。协议之上全部纯逻辑;`LiveProcessSource` 为 Darwin 薄适配器,`SyntheticProcessSource` 供测试与 SwiftUI 预览。
- **采集(Live)**:`proc_listallpids` 列进程;路径 `proc_pidpath`;CPU 用 `PROC_PIDTASKINFO` 的 `pti_total_user+system` 差分除以墙钟(与活动监视器同算法);内存 `pti_resident_size` / 物理足迹 `proc_pid_rusage`;磁盘字节 rusage v3;argv 用 `sysctl KERN_PROCARGS2`(缓冲布局 = argc + execpath + argv,解析时跳过第一个字符串);cwd 用 `PROC_PIDVNODEPATHINFO`(`vnode_info_path` 布局需手写或以少量 C 代码引入);ppid 用 `sysctl KERN_PROC` 的 `kp_eproc.e_ppid`(宏不导入 Swift)。全部已在本机探针验证。
- **归组引擎(纯函数)**:输入 = 一次快照 + 出生登记表 + 项目根列表,输出 = 组列表。三层逐级 fallback:① App 归属——可执行路径含 `.app/Contents/MacOS/` 即归属该 bundle(读 `CFBundleName` 作显示名),子进程跟随父进程;② 父链上溯——非 bundle 进程沿 ppid 向上走到有归属的祖先或 launchd;③ 项目归因——dev 类进程按 cwd 优先、argv 中路径次之与项目根做前缀匹配,命中 `.worktrees/<name>` 显示"项目名 @ worktree"。兜底三分类:系统(WindowServer、内核任务)、后台服务(launchd domain 推断)、孤儿进程(橙色)。
- **出生登记(内存版)**:每 2s 扫描新出现的 pid,出生时记录父链快照;查询时活链优先、断链查登记。重启即失,可接受(P0 决定,SQLite 随 P1)。
- **CPU 双口径**:组 CPU% / 进程 CPU% = 单核 100% 累加(445% 合法);菜单栏数字 = 系统 CPU 负载,全部进程之和 ÷ 逻辑核数,0–100%。
- **历史**:仅内存环形缓冲(1h、5s 粒度),P0 不落盘、不展示曲线。
- **UI**:菜单栏 = 单一系统 CPU 负载数字(>70% 变红);弹窗 = Top-5 组卡(组名+图标 / 组 CPU% / 内存 / "N 进程"),固定组 CPU% 降序,系统组参榜;组卡展开 = 组内进程平铺(CPU 降序),行内显示 pid/名字/CPU/内存;点进程行 = 详情(cwd、完整 argv、启动时长、父链面包屑);sparkline 不做。设置 scene = 项目根目录列表编辑器(增/删)。
- **kill**:单进程与整组两种,均弹确认对话框;整组 = 枚举组内全部进程后发信号。
- **文案**:中文。
- **依赖**:P0 零第三方依赖。

## Testing Decisions

- 只测外部行为,不测实现细节:对归组引擎,断言"这棵合成进程树归出这些组",不断言内部遍历顺序。
- **归组引擎 / 出生登记 / CPU 差分 / 环形缓冲**:纯逻辑单元测试,夹具用 `SyntheticProcessSource` 构造合成进程树——核心夹具即验收锚点场景(octok-client 门禁树:rustc×N ← cargo ← node ← ZCode;OrbStack;常驻 WaifuX;断链孤儿)。
- **LiveProcessSource**:冒烟测试(返回进程数 > 0;能取到本机 zsh 的路径;CPU% 落在合理区间)——这是探针已验证的部分,不重复深测。
- **UI**:不写单元测试,以 SwiftUI 预览(接 Synthetic 源)+ 验收场景手动下钻代替。
- 绿地仓库,无先例;测试与实现同置于 Xcode 测试 target。

## Out of Scope

- sparkline 与任何历史曲线展示;SQLite 持久化与 30 天历史(P1)
- 告警引擎、通知(P1)
- dev server 侦测与"可释放 X GB"卡片(P1)
- 复制诊断报告(P1)
- GPU / 能耗 / 网络指标;root helper(SMAppService)系统全量视角(P2)
- MCP server(P2)
- 菜单栏多指标可配、可拖拽排序;英文/多语言;App Store 分发;音量/蓝牙等 Vitals 周边功能(不做)

## Further Notes

- **P0 验收锚点**(真实场景):弹窗正确归组显示"octok-client 门禁(400%+ 级别)/ OrbStack / WaifuX",点击可下钻到 rustc/vitest 进程的 cwd 与 argv。
- 采集层起点:`docs/probe.swift`(本机已验证的 API 调用全集)。
- 遵守 ADR-0001(SwiftUI 栈)、ADR-0002(不开沙盒);词汇表 `GLOSSARY.md` 为唯一术语来源。
