# 03: 归组引擎:三层归属 + 兜底(纯逻辑)

**What to build:** 产品灵魂:纯函数归组引擎——输入一次快照 + 出生登记表 + 项目根列表,输出组列表(组名、类别、聚合的 CPU/内存/进程集合)。三层逐级 fallback:① App 归属(路径含 `.app/Contents/MacOS/` → bundle 名,子进程跟随);② 父链上溯(沿 ppid 走到有归属的祖先或 launchd);③ 项目归因(cwd 优先、argv 路径次之,与项目根前缀匹配;`.worktrees/<name>` → "项目名 @ worktree")。兜底三分类:系统(WindowServer、内核)、后台服务(launchd domain 推断)、孤儿进程。含内存版出生登记:登记新 pid 出生时的父链,断链时回查。全部以验收场景的合成进程树为夹具做单元测试,不碰真实 OS。

**Blocked by:** 02(快照模型与 Synthetic 源)。

**Status:** ready-for-agent

- [ ] 合成夹具:octok-client 树(rustc×N ← cargo ← node ← ZCode.app)归组为"项目 @ worktree",组 CPU% 为 N 个 rustc 之和(可超 100%)
- [ ] Chrome Helper(Renderer/GPU/XPC)全部跟随宿主 App 归属,应用仅一组
- [ ] 中间父进程已死(断链到 launchd)时,出生登记回查仍能归对
- [ ] 出生登记无记录的断链进程落"孤儿进程"类;WindowServer/内核落"系统";launchd 服务落"后台服务"
- [ ] 无项目根配置时,dev 进程按 App 归属/兜底正常降级
- [ ] 引擎为纯函数:同输入同输出,不持 OS 状态

## Comments
