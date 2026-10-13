# 06: 组内下钻:进程明细

**What to build:** 回答"组里到底是谁":点击组卡展开组内进程平铺列表(按 CPU% 降序),每行显示进程名、pid、CPU%、内存;再点某行显示详情:cwd、完整 argv(可滚动/可复制)、启动时长("已 25 分钟")、父链面包屑一行("rustc ← cargo ← node ← ZCode"——出生登记/活链的直观呈现,从进程自身追溯到有归属的祖先)。

**Blocked by:** 05。

**Status:** ready-for-agent

- [x] 点组卡展开/收起进程列表,列表按 CPU% 降序
- [x] 每行含进程名、pid、CPU%、内存
- [x] 点进程行显示 cwd 与完整 argv,长 argv 不破坏布局、可复制
- [x] 显示启动时长;父链面包屑按"进程 ← 父 ← 祖先 ← 归宿"渲染
- [x] 组内进程数较多(数十行)时滚动流畅
- [x] 下钻数据来自最近一轮采样,不额外触发采集

## Comments

- 06 实现:纯逻辑在 `PulseFormat.uptime`/`processName`、`ParentChainQuery`(活链优先、断链/重挂回查出生登记,bundle 祖先或 launchd 为终点)、`DrilldownState`(行/详情视图模型,顺序沿用引擎契约);UI 在 `ProcessDrilldownView`(LazyVStack + 可滚动可复制 argv)+ `DashboardView` 组卡展开。列表高度上限 480 的贴合度留给工单 09 手动 QA。
