# 08: dev server finder

**What to build:** 主窗口总览页出现 dev server 卡:列出在跑的开发服务进程(闲置时长/内存/监听端口),argv 模式识别(vite/next dev/webpack/vitest watch/jest watch/runserver 等);只有候选进程才做端口扫描;「闲置」标签 = 最近 10 分钟 CPU≈0(注入时钟判定);「全部停止」走现有确认流,永不自动杀;闲置 >24h 告警规则接入工单 07 的引擎并真实可触发。popover 不放此卡。

**Blocked by:** 07(告警引擎)

**Status:** ready-for-agent

- [ ] argv 分类器单测:已知模式清单 + 误报例(如路径里碰巧含 vite 的非 dev 进程)
- [ ] 端口扫描仅对候选进程;成本约束有测试体现
- [ ] 闲置判定注入时钟单测;卡片数据(闲置/内存/端口)与真实进程吻合
- [ ] 「全部停止」经确认流;单进程 kill 已有能力复用不重造
- [ ] 闲置 24h 规则用合成快照注入引擎验证真实触发
