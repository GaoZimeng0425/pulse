# 03: Live 扫描器 +「清理」tab 骨架 + 全卷扫描闭环

**What to build:** 真实现挂上边界协议:getattrlistbulk 整批枚举(petal 主路径;iCloud dataless 项跳过、绝不触发回源;dust 护栏——block 虚报封顶 / EINTR 重试上限 / 错误台账 / 低优先级限并发可取消;并发与进度按 01 的量级基线定)。主窗口第 12 个药丸 tab「清理」(取磁盘色族;若需新色先入 DESIGN.md 表)+ 子药丸壳「开发者垃圾 | 空间地图 | 清理历史」+ 手动扫描按钮 / 进度 / 取消 / 结果缓存(缓存到下次扫描)+ FDA 能力检测与引导(直达系统设置隐私面板;未授时受限目录进部分扫描台账并在界面明示,不报错)。清理是用户触发的按需动作:不挂每轮调度、无常驻采集,MetricTab 注册进既有注册表测试。UI 形态以原型 B 变体为准(分支 prototype/cleaner-ui)。

**Blocked by:** 02

**Status:** done

- [x] 起点验收:点清理 tab → 全卷扫描有进度、可取消;取消后再进沿用缓存
- [x] 12 个药丸在 720 最小窗宽不触发溢出菜单(工具栏预算规矩)
- [x] 未授 FDA:能扫的照扫,受限如实标「部分扫描」,无报错、无假 0
- [x] 稳态零增量:无任何常驻采集挂上(窗口指纹口径不变)
- [x] Live 薄壳测试进 PulseTests;真机观感(时长 / 取消手感)留 09 目验


## Comments

**2026-10-28 实施完毕(feat/p4-tab,新增 9 例测试,全量 852 绿:核心 475 + app 377):**

- **交付**:LiveCleanDirectoryEnumerator(探针 11 解析器落码:RETURNED_ATTRS 必带 / 20B attrset / 4 字节紧凑 / FILEID 8B / cmnext 批量;EINTR 999 上限;EACCES→permissionDenied、ENOENT→vanished);CleanerModel(@MainActor @Observable 状态机,扫描跑 .utility detached Task,进度每 2048 项跳主线程,取消保留部分结果,结果内存缓存);CleanerTabView(页头 + 玻璃子药丸「开发者垃圾|空间地图|清理历史」+ 扫描卡/摘要卡/占位卡,FDA 横幅 = 台账权限失败数 → 去授权深链);MetricTab 加 cleaner(主窗口入列、popoverAxis 排除、磁盘色族、sparkles 符号、无家族无排行闸)。
- **测试**:轴与注册面 4 例(displayAxis 含 / popoverAxis 不含 / 元数据 / 键盘轴位);Live 枚举 2 例(真 APFS 临时目录:类型/大小/FILEID 对 stat/**克隆语义逐字兑现——原件在克隆在场时 reclaimable=0**,与探针 11 ④ 一致;权限与 vanished 分类);模型 3 例(生命周期/缓存/FDA 判据来自台账/重扫替换/无权限失败无横幅)。既有 MetricTabModelTests 轴预期随 cleaner 更新(电池后历史前)。
- **720 药丸预算**:构造上成立(selectedOnly 图标态 12 枚 ≈606pt + 搜索 132 + 齿轮 < 720);实机目验归 09。
- **稳态零增量**:不挂 MonitorFeatures / SensorScheduler,MetricTab.cleaner 无家族无排行(测试钉死);关窗随 MainWindowGate 销毁模型。
- 扫描进度条用「斜率式伪进度」不显示百分比数字(全卷总量因机而异,假数不上屏);摘要卡含 block 口径对照与口径注记(GLOSSARY 实际占用)。
