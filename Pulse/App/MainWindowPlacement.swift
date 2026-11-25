import AppKit
import PulseCore

/// 主窗口离屏守卫(arch-review-2026-11-24/13 自 MainWindowView 迁出):只做取数与落位,
/// 几何判定在 `WindowPlacement`(PulseCore 纯函数,两套屏幕坐标统一换算,单测覆盖)。
///
/// 窗口落在**用户看不见的屏**(典型:外接屏断电留幻影屏,系统状态恢复把窗口
/// 还回旧坐标)时,搬回用户光标所在的在线屏。判据依据 2026-10-16 验收走查的
/// 实测排除法:幻影屏在 CG/NSScreen 层仍是"活跃在线",甚至可以是
/// NSScreen.main(用户把它设过主屏)——"面板灭没灭"没有任何 API 可问,唯一
/// 骗不掉的锚点是用户此刻的光标(点"打开主窗口"时光标必然在他们看得见的
/// 屏上);光标定位不到就退回内建屏(笔记本开盖必亮)。
@MainActor
enum MainWindowPlacement {
    static func repositionIfOffscreen() {
        let window = NSApp.windows.first {
            $0.identifier?.rawValue == MainWindowSceneID.value || $0.title == "Pulse"
        }
        guard let window else {
            LogService.info(
                "离屏守卫:未找到主窗口(windows=\(NSApp.windows.map { "\($0.title)|\($0.identifier?.rawValue ?? "-")" }.joined(separator: ",")))",
                category: "MainWindow"
            )
            return
        }
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        guard onlineCount > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &ids, &onlineCount)
        let displays = ids.prefix(Int(onlineCount)).map {
            WindowPlacement.Display(cgBounds: CGDisplayBounds($0), isBuiltin: CGDisplayIsBuiltin($0) != 0)
        }
        guard let origin = WindowPlacement.relocatedOrigin(
            windowFrame: window.frame,
            displays: displays,
            cursor: CGEvent(source: nil)?.location ?? .zero,
            // CG 全局坐标原点 = 主屏左上角;翻转到 AppKit 系用主屏高。
            mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height
        ) else { return }
        LogService.info("离屏守卫:窗口在 \(window.frame),按光标搬回 \(origin)", category: "MainWindow")
        window.setFrameOrigin(origin)
    }
}
