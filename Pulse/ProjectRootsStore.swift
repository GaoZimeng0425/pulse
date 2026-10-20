import Foundation
import Observation
import PulseCore

/// 项目根(GLOSSARY)列表的持久层与唯一事实来源(工单 07 设置窗)。
/// UserDefaults 存纯路径字符串数组——无沙盒(ADR-0002),不需要安全作用域书签。
/// 读写经注入 defaults 隔离:单测注入独立 suite(ProjectRootsStoreTests),
/// SwiftUI 预览注入无副作用闭包。
@Observable
@MainActor
final class ProjectRootsStore {
    /// UserDefaults 键:纯路径字符串数组。键名即持久化契约,勿改(改了会丢用户配置)。
    static let storageKey = "projectRoots"

    /// 当前项目根列表(用户增删顺序保留;归一后与现有根相同的不重复进入)。
    /// SystemMonitor 拉起时取初值,之后每次增删由组合根喂给 `setProjectRoots`。
    private(set) var projectRoots: [String]

    private let persist: ([String]) -> Void

    /// 注入读写闭包的构造(测试 / 预览):load 决定启动初值,persist 决定落盘副作用。
    init(load: () -> [String], persist: @escaping ([String]) -> Void) {
        self.projectRoots = load().map(PathNormalization.normalize)
        self.persist = persist
    }

    /// 生产构造:UserDefaults(标准库);测试注入独立 suite。
    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            load: { defaults.stringArray(forKey: Self.storageKey) ?? [] },
            persist: { roots in defaults.set(roots, forKey: Self.storageKey) }
        )
    }

    /// 新增项目根(文件夹选择器选中的目录)。归一后与现有根相同则幂等忽略。
    func add(_ root: String) {
        let normalized = PathNormalization.normalize(root)
        guard !normalized.isEmpty, !projectRoots.contains(normalized) else { return }
        projectRoots.append(normalized)
        persist(projectRoots)
    }

    /// 移除项目根。列表中没有该根时安静无操作。
    func remove(_ root: String) {
        let normalized = PathNormalization.normalize(root)
        let before = projectRoots
        projectRoots.removeAll { $0 == normalized }
        if projectRoots != before {
            persist(projectRoots)
        }
    }
}
