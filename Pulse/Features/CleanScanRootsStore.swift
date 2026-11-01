import Foundation
import Observation
import PulseCore

/// 清理扫描根(p4-cleaner/05,用户拍板:与归组的项目根两套配置解耦,零共享)的
/// 持久层与唯一事实来源。形态与 CleanExclusionsStore 同款:UserDefaults 存纯路径
/// 字符串数组,读写经注入闭包隔离。语义在 PulseCore.ProjectArtifactMatcher
/// (根的直接子目录 = 项目);本类只做持久化与发布。消费:清理页项目产物匹配 +
/// 设置页「清理」建议清单勾选 / 自添。
@Observable
@MainActor
final class CleanScanRootsStore {
    /// UserDefaults 键:纯路径字符串数组。键名即持久化契约,勿改(改了会丢用户配置)。
    static let storageKey = "cleanerScanRoots"

    /// 当前扫描根(归一后;顺序 = 用户加入顺序)。与归组 ProjectRootsStore 无任何共享。
    private(set) var paths: [String]

    private let persist: ([String]) -> Void

    /// 注入读写闭包的构造(测试 / 预览)。
    init(load: () -> [String], persist: @escaping ([String]) -> Void) {
        paths = load().map { PathNormalization.normalize($0) }.filter { $0.count > 1 }
        self.persist = persist
    }

    /// 生产构造:UserDefaults(标准库);测试注入独立 suite。
    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            load: { defaults.stringArray(forKey: Self.storageKey) ?? [] },
            persist: { paths in defaults.set(paths, forKey: Self.storageKey) }
        )
    }

    /// 加入扫描根(建议清单勾选 / 文件夹选择器)。重复幂等;"/" 拒收(那是全卷扫描,
    /// 不是项目扫描根)。
    func add(_ path: String) {
        let normalized = PathNormalization.normalize(path)
        guard normalized.count > 1, !paths.contains(normalized) else { return }
        paths.append(normalized)
        persist(paths)
    }

    /// 移除扫描根。列表中没有该项时安静无操作。
    func remove(_ path: String) {
        let normalized = PathNormalization.normalize(path)
        guard paths.contains(normalized) else { return }
        paths.removeAll { $0 == normalized }
        persist(paths)
    }
}
