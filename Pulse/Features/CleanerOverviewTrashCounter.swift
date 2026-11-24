import Foundation
import Observation
import PulseCore

// 总览废纸篓清点子状态机(solid-split/02 步骤 2,自 CleanerModel 抽出)。
// 职责单一:清点一次废纸篓供总览显示——读数四态、在飞任务去重、授权门卫
// (弹窗只许出现在用户动作那一刻)全在这;CleanerModel 只留转发面。

/// 总览废纸篓读数的状态。「没查」「查了读不到」「查到了」必须分开:读不到不是空,
/// 更不是 0(防御性数据纪律)——视图对前两态一律走占位,不出数字。
enum OverviewTrashPhase: Equatable {
    /// 没查:占位 + 废纸篓卡上的显式「清点」入口。
    case notCounted
    /// 清点在飞。`lastGood` = 上次读到的数——刷新期间继续显示它,不闪占位
    /// (首次清点 / 失败后重试为 nil,那时才转圈)。
    case counting(lastGood: TrashInventory?)
    /// 查了但读不到(权限被拒 / 宗卷不可用):占位 + 显式重试入口,不自动重试。
    /// 上次读数一并作废——读不到之后再挂旧数字就是伪造。
    case failed
    case counted(TrashInventory)

    /// 当前可显示的读数:查到了,或刷新在飞时的上次读数;没查 / 读不到 = nil。
    var reading: TrashInventory? {
        switch self {
        case let .counted(inventory): inventory
        case let .counting(lastGood): lastGood
        case .notCounted, .failed: nil
        }
    }
}

@Observable
@MainActor
final class OverviewTrashCounter {
    private(set) var phase: OverviewTrashPhase = .notCounted

    /// 当前可显示的读数(查到了,或刷新在飞时的上次读数;没查 / 读不到 = nil)。
    var reading: TrashInventory? {
        phase.reading
    }

    /// 清点的在飞任务(主 actor 独占读写):重复发起先取消旧的,见 `refresh`。
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 自动刷新门卫(本会话内存态,重启从严):清点读成功过才置真,任何一次读失败
    /// 回落为假。凭什么:清点要枚举 /Volumes/*/.Trashes,可能触发「可移除宗卷」授权
    /// 弹窗——弹窗只许出现在用户动作那一刻(CODING_STANDARDS 权限纪律,蓝牙票先例)。
    /// 首次成功只可能来自显式入口(门卫关着,自动路径进不来),授权在那一刻定下;
    /// 失败回落 = 被拒不自动重试。
    /// 前提的边界,如实记:放行后自动路径枚举的是**当时**挂载的宗卷,清点成功之后
    /// 才挂上、授权从未定过的宗卷不在那次用户动作的覆盖内——本门卫不按宗卷集合
    /// 收紧(那需要一个不碰宗卷内容的探测接缝),此处按「读成功过即放行」收口。
    @ObservationIgnored private var autoRefreshUnlocked = false

    @ObservationIgnored private let source: @Sendable () async -> TrashInventory?

    init(source: @escaping @Sendable () async -> TrashInventory?) {
        self.source = source
    }

    /// 自动入口(进总览页的可见性切换):门卫放行才清点,否则原地不动——没查就
    /// 保持「没查」,由废纸篓卡的显式「清点」承担首次读数。
    func refreshIfUnlocked() {
        guard autoRefreshUnlocked else { return }
        refresh()
    }

    /// 显式入口:清点一次废纸篓,只为总览显示。**只许挂在用户动作上**(废纸篓卡
    /// 「清点」按钮、清空完成后的原地刷新);可见性切换走 `refreshIfUnlocked`。
    /// 代价不小:每个顶层条目整树递归求分配大小(`LiveCleanTrashExecutor.allocatedSize`),
    /// 大废纸篓可达秒级,所以放 utility 档后台任务。
    /// 不重复发起:在飞的旧任务先取消。清点本身没有取消点(同步文件遍历),取消的
    /// 落点在结果应用前——被取代的任务读完也不写态,过期读数不会后到覆盖新读数。
    /// 写态全在主 actor,天然串行。
    func refresh() {
        task?.cancel()
        phase = .counting(lastGood: reading)
        task = Task.detached(priority: .utility) { [weak self, source] in
            let inventory = await source()
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.apply(inventory)
            }
        }
    }

    /// 清点结果落位(显式清点 / 清空前清点共用;beginEmptyTrash 也走这里)。调用方
    /// 手里的读数比在飞任务新,在飞任务一并作废。失败不静默吞:态落 `.failed`
    /// (视图占位)+ 日志留痕。
    func apply(_ inventory: TrashInventory?) {
        task?.cancel()
        task = nil
        if let inventory {
            autoRefreshUnlocked = true
            phase = .counted(inventory)
        } else {
            autoRefreshUnlocked = false
            phase = .failed
            LogService.warn("废纸篓清点读不到(权限被拒 / 宗卷不可用),总览走占位", category: "Cleaner")
        }
    }
}
