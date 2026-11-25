import CoreGraphics

// 主窗口离屏拉回的纯几何(arch-review-2026-11-24/13)。
//
// 两套屏幕坐标:
// - CG 全局坐标(`CGDisplayBounds`、`CGEvent.location`):原点在主屏左上角,y 向下;
//   主屏上方的屏 y 为负。
// - AppKit 坐标(`NSWindow.frame`、`setFrameOrigin`):原点在主屏左下角,y 向上;
//   主屏上方的屏 y > 主屏高。
// 两系 x 相同,y 互为翻转:`y_appkit = 主屏高 − y_cg − h`。旧实现把 CG 屏矩形直接与
// AppKit 窗口 frame 比较、再把 CG 算出的原点交给 setFrameOrigin——单屏或左右并排时
// 两系 y 碰巧接近看不出错,外接屏**上下**摆放时误判离屏并搬到错误位置。
// 这里先把屏与光标统一换算到 AppKit 系,判定与钳制只在一个坐标系里做。

public enum WindowPlacement {
    /// 一块在线屏:CG 全局坐标下的边界 + 是否内建屏。
    public struct Display: Equatable, Sendable {
        public let cgBounds: CGRect
        public let isBuiltin: Bool

        public init(cgBounds: CGRect, isBuiltin: Bool) {
            self.cgBounds = cgBounds
            self.isBuiltin = isBuiltin
        }
    }

    /// 屏 / 窗矩形 CG → AppKit:x 不变,y 按主屏高翻转。
    public static func appKitRect(fromCG rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainDisplayHeight - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// 点 CG → AppKit(光标位置)。
    public static func appKitPoint(fromCG point: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    /// 窗口不在目标屏上时,返回搬回后的新原点(AppKit 坐标);已在目标屏上 / 无在线屏 → nil。
    ///
    /// 目标屏 = 光标所在屏(用户此刻看得见的屏);光标无归属则内建屏,再退最宽的屏。
    /// 搬法:居中到目标屏,四边留 8pt 钳制。
    /// - Parameters:
    ///   - windowFrame: 窗口 frame,AppKit 坐标。
    ///   - displays: 在线屏,CG 坐标。
    ///   - cursor: 光标,CG 坐标。
    ///   - mainDisplayHeight: 主屏(CG 原点所在屏)高度,翻转用。
    public static func relocatedOrigin(
        windowFrame: CGRect,
        displays: [Display],
        cursor: CGPoint,
        mainDisplayHeight: CGFloat
    ) -> CGPoint? {
        let screens = displays.map {
            (rect: appKitRect(fromCG: $0.cgBounds, mainDisplayHeight: mainDisplayHeight), isBuiltin: $0.isBuiltin)
        }
        let pointer = appKitPoint(fromCG: cursor, mainDisplayHeight: mainDisplayHeight)
        let target = screens.first { $0.rect.contains(pointer) }?.rect
            ?? screens.first { $0.isBuiltin }?.rect
            ?? screens.map(\.rect).max { $0.width < $1.width }
        guard let target, !target.intersects(windowFrame) else { return nil }
        let inset: CGFloat = 8
        let x = target.midX - windowFrame.width / 2
        let y = target.midY - windowFrame.height / 2
        return CGPoint(
            x: max(target.minX + inset, min(x, target.maxX - windowFrame.width - inset)),
            y: max(target.minY + inset, min(y, target.maxY - windowFrame.height - inset))
        )
    }
}
