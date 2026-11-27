import Foundation

// MARK: - 条目标志(p7-cleaner/01;GLOSSARY「条目标志」)

//
// 清单行、确认清单、清理历史三处共用这一份:候选带上标志,界面照标志清单出小标。
// 标志只陈述事实,不是安全档(GLOSSARY「安全档」),也不参与自动勾选判定。
// 「需要管理员权限」由系统级条目给出(接 GLOSSARY「运行时授权」),「未识别」由
// 通用发现给出(GLOSSARY「通用发现」);本票只登记标志,两个来源由后续票落地。
// 文案与悬停说明只在这里定一处,免得三处各写一套。
// 叫「标志」不叫「标记」:「标记」在本仓另有所指——空间地图的「可清理标记」、
// 项目产物的「项目标记」(识别项目用的文件,如 package.json)。

/// 候选上的条目标志。
public enum JunkCandidateFlag: String, Sendable, Equatable, CaseIterable {
    /// 系统目录里的条目:移走前要弹一次系统管理员密码框。
    case requiresAuthorization
    /// 名单外的条目:说不出它属于哪个工具,只能归「先检查」。
    case unidentified

    /// 小标文案。
    public var title: String {
        switch self {
        case .requiresAuthorization: "需要管理员权限"
        case .unidentified: "未识别"
        }
    }

    /// 悬停说明:小标自己解释自己。只陈述这条目是什么样的事实,不描述「点了会发生什么」
    /// ——同一份说明也挂在清理历史的行上(那里可能是失败行),流程话在那处不成立。
    public var help: String {
        switch self {
        case .requiresAuthorization:
            "在系统目录里:移走它需要一次系统管理员授权(弹出系统密码框)"
        case .unidentified:
            "不在已知名单里,说不出它属于哪个工具:只列在「先检查」,不进自动勾选"
        }
    }
}

extension JunkCandidateFlag {
    /// 标志清单的规范形:按 `allCases` 的固定序排列并去重——需授权在前,它决定「点了会
    /// 发生什么」,比认不认识更要紧。候选只存规范形,比较与显示都不必再各自排序。
    /// 模块内使用:候选的构造入口是唯一调用方,不对外暴露。
    static func normalized(_ flags: [JunkCandidateFlag]) -> [JunkCandidateFlag] {
        let present = Set(flags)
        return allCases.filter { present.contains($0) }
    }
}
