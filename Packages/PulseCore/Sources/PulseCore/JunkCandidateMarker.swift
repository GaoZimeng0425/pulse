import Foundation

// MARK: - 候选的客观标记(p7-cleaner/01)

//
// 清单行、确认清单、清理历史三处共用这一份:候选带上标记,界面照标记清单出小标。
// 标记只陈述事实,不是安全档(GLOSSARY「安全档」),也不参与自动勾选判定。
// 「需要管理员权限」由系统级条目给出(接 GLOSSARY「运行时授权」),「未识别」由
// 通用发现给出(GLOSSARY「通用发现」);本票只登记标记,两个来源由后续票落地。
// 文案与悬停说明只在这里定一处,免得三处各写一套。

/// 候选上的客观标记。
public enum JunkCandidateMarker: String, Sendable, Equatable, CaseIterable {
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

public extension JunkCandidate {
    /// 候选的标记清单。固定序:需授权在前——它决定「点了会发生什么」,比认不认识更要紧。
    var markers: [JunkCandidateMarker] {
        var out: [JunkCandidateMarker] = []
        if requiresAuthorization {
            out.append(.requiresAuthorization)
        }
        if unidentified {
            out.append(.unidentified)
        }
        return out
    }
}
