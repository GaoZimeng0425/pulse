# 13: 主窗口离屏拉回混用两套屏幕坐标

**Status:** ready-for-agent

**背景:** 核实 09 时发现(2026-11-24)。`Pulse/Views/MainWindowView.swift` `repositionIfOffscreen()`:

- `CGDisplayBounds` 与 `CGEvent.location`(光标)是**左上角原点、y 向下**的全局坐标;
- `window.frame` 与 `setFrameOrigin` 是 AppKit **左下角原点、y 向上**的坐标(以主屏底边为 0);
- 代码直接 `target.intersects(window.frame)`,并把按 CG 算出的 origin 传给 `setFrameOrigin`。

单屏、或外接屏左右并排时,两套 y 恰好大致对称,看不出错;**外接屏上下摆放**时(CG 里上方屏 y 为负,
AppKit 里为 > 主屏高),会把在屏上的窗口误判为离屏并搬走,或搬到错误位置;y 方向的钳制也按错的系算。

**用户会看到:** 外接屏放在笔记本上方时,点「打开主窗口」窗口跳到别的屏或屏外;或真离屏时没被拉回。

**Agent Brief:**
1. 先写探针证实(不需要动鼠标):纯函数单测构造「主屏 1512×982 + 上方外接屏 2560×1440」的两套坐标,
   断言现实现的判定错误(红)。
2. 坐标换算抽成 PulseCore 纯函数:CG 矩形 → AppKit 矩形(`y' = 主屏高 − y − h`,主屏 = `CGMainDisplayID()`
   的 bounds),判定与钳制全在 AppKit 坐标系内完成;app 侧只做取数和 `setFrameOrigin`。
3. 正反例测试:并排、上下、主屏在右、光标在副屏;单屏行为与现在一致。
4. 顺带把函数从 View 挪到 `Pulse/App`(09 的同一处建议,成本为零)。

**验收:** 换算单测覆盖四种排布;单屏行为不变;`sh scripts/check.sh` 全绿。实机验证需外接屏上下摆放,
由用户方便时确认(不擅自动鼠标)。
