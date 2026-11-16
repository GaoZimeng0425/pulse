# 02: 清理 tab 挪到磁盘旁

**What to build:** displayAxis 里「清理」挪到「磁盘」紧后:总览/CPU/内存/GPU/传感器/
外设/**磁盘/清理**/网络/(服务)/智能体/电池/历史。极小改。

**背景:** 2026-11-16 用户拍板「清理放磁盘旁边」,不深并(理由见 `../spec.md`);
tab 总数不变。与 01 无顺序耦合(01 不动顺序),同批并行时注意 02 先合或后合都需
重跑 tab 序断言。

**Status:** done(2026-11-16,feat/tab-regroup@378a77b)

- [x] `MetricTab.allCases` 顺序调整(键盘 ←/→ 轴随之;枚举声明序即 allCases 序)
- [x] tab 序断言测试更新(rawValues 序 / 标题 / moveRight / moveLeft / 无电池轴);
      弹窗轴逻辑不动(popoverAxis 仍排除清理)
- [x] `sh scripts/check.sh` 全绿(worktree 流程)

**Out of scope:** 深并清理进磁盘页(用户明确不选);磁盘页加「去清理」入口跳转卡
(未拍板,不做——相邻已达成归位目标)。
