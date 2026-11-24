import Foundation
import PulseCore

// MARK: - Live 进程活动源(p4-cleaner/05,在用保护的输入)

/// 活动源 Live 实现:板上的最新一轮 → 三元组推导(分类 / 合并原因)。
/// 每次调用重新推导,不做任何缓存(spec 在用保护:「判定永不缓存」)。
/// home 供第四路(p6-cleaner/02)挂 AI 服务标记;默认真家目录,
/// 装配点(PulseApp / MainWindowView)不必为此改动。
struct LiveCleanActivitySource: CleanActivitySource {
    let board: CleanActivityBoard
    let home: String

    init(board: CleanActivityBoard, home: String = NSHomeDirectory()) {
        self.board = board
        self.home = home
    }

    func activeEntries() -> [CleanActivityEntry] {
        CleanActivityDerivation.entries(from: board.current(), home: home)
    }
}
