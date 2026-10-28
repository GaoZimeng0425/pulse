import Foundation
import Observation
import PulseCore

/// 排除目录(GLOSSARY)列表的持久层与唯一事实来源(p4-cleaner/04)。
/// 形态与 ProjectRootsStore 同款:UserDefaults 存纯路径字符串数组(无沙盒,ADR-0002,
/// 不需安全作用域书签);读写经注入闭包隔离,单测注入独立 suite / 无副作用闭包。
/// 语义全部出自 PulseCore.CleanExclusions(只收窄、覆盖去重)——本类只做持久化与发布。
/// 两处消费:清理页扫描时喂 `SpaceScanOptions.excludedPathPrefixes`、删除前 CleanPlan 二次判定;
/// 设置页「清理」管理增删。
@Observable
@MainActor
final class CleanExclusionsStore {
    /// UserDefaults 键:纯路径字符串数组。键名即持久化契约,勿改(改了会丢用户配置)。
    static let storageKey = "cleanerExcludedPaths"

    /// 当前排除前缀(归一后;顺序 = 用户加入顺序,被更宽前缀吸收的条目会消失)。
    private(set) var paths: [String]

    private let persist: ([String]) -> Void

    /// 注入读写闭包的构造(测试 / 预览):load 决定启动初值,persist 决定落盘副作用。
    init(load: () -> [String], persist: @escaping ([String]) -> Void) {
        paths = load().reduce(into: []) { $0 = CleanExclusions.adding($1, to: $0) }
        self.persist = persist
    }

    /// 生产构造:UserDefaults(标准库);测试注入独立 suite。
    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            load: { defaults.stringArray(forKey: Self.storageKey) ?? [] },
            persist: { paths in defaults.set(paths, forKey: Self.storageKey) }
        )
    }

    /// 加入排除(右键菜单 / 设置页选择器)。已被覆盖或重复则幂等无操作。
    func add(_ path: String) {
        let next = CleanExclusions.adding(path, to: paths)
        guard next != paths else { return }
        paths = next
        persist(paths)
    }

    /// 移除排除。列表中没有该项时安静无操作。
    func remove(_ path: String) {
        let next = CleanExclusions.removing(path, from: paths)
        guard next != paths else { return }
        paths = next
        persist(paths)
    }
}
