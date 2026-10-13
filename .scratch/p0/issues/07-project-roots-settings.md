# 07: 项目根配置

**What to build:** 项目归因的用户入口:设置窗(Settings scene)提供项目根目录列表的图形化增删(文件夹选择器),列表持久化(UserDefaults)并在下轮采样生效——添加一个根后,散落的 rustc/node/vitest 立刻从"孤儿/App 归属"变为"项目名 @ worktree"组。设置窗可从弹窗进入。

**Blocked by:** 05。

**Status:** done

- [x] 弹窗有设置入口,打开设置窗
- [x] 项目根列表可增(文件夹选择器)可删,重启后保留
- [x] 添加项目根后 ≤1 轮采样内,相关进程以"项目名 @ worktree"组名出现
- [x] 删除项目根后,该项目的组在 ≤1 轮采样内消失/降级
- [x] 配置为空时归组行为与 03 的降级路径一致(不报错)

## Comments

- 工单完成(p0/07):新增 `ProjectRootsStore`(@MainActor @Observable,UserDefaults 存纯路径字符串数组,键 `projectRoots`;读写经注入 defaults 隔离,尾斜杠归一 + 幂等去重)与 `ProjectRootsSettingsView`(SwiftUI Settings scene:文件夹选择器 NSOpenPanel 添加、行内删除、空态文案与口径说明,中文)。热更新接缝:`GroupingPipeline.setProjectRoots`(下一轮 update 即以新根归组,`configuration` 改 `private(set) var`)→ `SystemMonitor.setProjectRoots`;组合根 `PulseApp` 显式 init 建 store、拉起即喂 `projectRoots:`,菜单栏标签视图 `onChange` 把设置窗增删推给 monitor。弹窗头部新增齿轮按钮(`openSettings()`)。测试:+8 store 用例(注入独立 suite,含重启往返)+2 管线热更新用例(设根下一轮出"octok-client @ worktree"组、清空下一轮降级回 03 路径),全套 74/74 绿;app 冒烟拉起正常。设置窗交互(选择器/窗口)按 spec 手动验收。
