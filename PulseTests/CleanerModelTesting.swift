import Foundation
@testable import Pulse
import PulseCore

/// 测试用工厂(arch-clean/01):参数与 `CleanerModel.init` 同名同序;原先默认走 Live 的
/// 三个参数(目录枚举 / 已装清点 / 废纸篓清点)默认给惰性替身——测试不再碰本机真
/// /Applications、真废纸篓、真目录树。其余默认与 init 一致。
@MainActor
extension CleanerModel {
    static func testing(
        exclusions: CleanExclusionsStore = CleanExclusionsStore(load: { [] }, persist: { _ in }),
        scanRoots: CleanScanRootsStore = CleanScanRootsStore(load: { [] }, persist: { _ in }),
        history: CleanHistoryStore? = nil,
        trash: any CleanTrashExecutor,
        directoryEnumerator: any CleanDirectoryEnumerator = FakeCleanDirectoryEnumerator(),
        activity: (any CleanActivitySource)? = nil,
        volumeSummaries: (@Sendable () -> [SpaceMapVolumeSummary])? = nil,
        scanCache: CleanScanResultStore? = nil,
        homeDirectory: String = NSHomeDirectory(),
        markerExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        installedAppInventory: @escaping @Sendable ([SpaceNode], Bool, String) -> InstalledAppInventory = { _, _, _ in
            .complete([])
        },
        trashInventory: @escaping @Sendable () async -> TrashInventory? = { nil },
        aiManifestReader: @escaping (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        scanCancelForceTimeout: TimeInterval = 5
    ) -> CleanerModel {
        CleanerModel(
            exclusions: exclusions,
            scanRoots: scanRoots,
            history: history,
            trash: trash,
            directoryEnumerator: directoryEnumerator,
            activity: activity,
            volumeSummaries: volumeSummaries,
            scanCache: scanCache,
            homeDirectory: homeDirectory,
            markerExists: markerExists,
            installedAppInventory: installedAppInventory,
            trashInventory: trashInventory,
            aiManifestReader: aiManifestReader,
            scanCancelForceTimeout: scanCancelForceTimeout
        )
    }
}
