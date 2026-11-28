import Foundation

// MARK: - 系统级规则(p7-cleaner/05;ADR-0012)

//
// 系统目录里的条目:列出与移走是两件事。这里只管「列」——扫描树 → 候选,与规则表 /
// 孤儿检测 / 通用发现同一条接缝。每条候选带「需要管理员权限」条目标志:移走它要走
// 运行时授权(接缝 `CleanSystemTrashExecutor`,在 CleanPlan.swift),不归用户态的废纸篓
// 执行器。起步只有一条:系统崩溃报告目录下满 7 天的普通文件(位置与 7 天阈值同对齐
// 对象,零搬码);规则族补齐见 06 票。
// 提权一侧不信任这里的判断:随包分发的复核脚本按同一个路径形状自己再核一遍
// (Pulse/Resources/SystemTrash/pulse-system-trash.sh)。路径与年龄两边各写一份,改一处
// 必须改另一处——不一致时的表现是「脚本逐项跳过」,不会多动。

/// 一条系统级规则:某个系统目录直接下面的、放满 `minimumAge` 的普通文件。
public struct SystemLevelRule: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let directory: String
    public let minimumAge: TimeInterval
    public let rationale: String
    public let symbolName: String

    public init(
        id: String,
        title: String,
        directory: String,
        minimumAge: TimeInterval,
        rationale: String,
        symbolName: String
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.minimumAge = minimumAge
        self.rationale = rationale
        self.symbolName = symbolName
    }
}

public enum SystemLevelRuleTable {
    public static let crashReportsDirectory = "/Library/Logs/DiagnosticReports"

    /// 「满 7 天」= 距修改时间不少于 604800 秒。
    public static let crashReportsMinimumAge: TimeInterval = 7 * 86400

    public static let builtin: [SystemLevelRule] = [
        SystemLevelRule(
            id: "system.crashReports",
            title: "过期的系统崩溃报告",
            directory: crashReportsDirectory,
            minimumAge: crashReportsMinimumAge,
            rationale: "系统目录里放满 7 天的崩溃与诊断报告,排查问题时才用得上,过期后没人再看。移走前会弹一次系统管理员密码框;进废纸篓的「Pulse 系统级」子目录,清空废纸篓前可随时找回。",
            symbolName: "doc.text.below.ecg"
        ),
    ]

    /// 扫描引擎需要为其保留文件节点的路径前缀:规则按文件判年龄,文件节点不在树上就
    /// 永远列不出。`CleanerModel` 建扫描选项时从这里取。
    public static var retainedFilePrefixes: [String] {
        builtin.map(\.directory)
    }
}

/// 扫描树 → 系统级候选。纯值、零 IO:读不到修改时间的文件证明不了年龄,不列。
public enum SystemLevelDetector {
    public static func detect(
        in trees: [SpaceNode],
        now: TimeInterval,
        excludedPathPrefixes: [String]
    ) -> [JunkCandidate] {
        var out: [JunkCandidate] = []
        for rule in SystemLevelRuleTable.builtin {
            guard let directory = SpaceNode.locate(path: rule.directory, in: trees) else { continue }
            for file in directory.children {
                // 只收直接下面的普通文件;名字以点开头的不算(那不是报告)。换行与制表符
                // 不收:条目要一行一个写进清单文件交给复核脚本,这类名字没法表达。
                guard file.kind == .file,
                      !file.name.hasPrefix("."),
                      !file.name.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }),
                      let modified = file.newestChangeEpoch,
                      now - modified >= rule.minimumAge,
                      !CleanExclusions.isExcluded(file.path, by: excludedPathPrefixes)
                else { continue }
                out.append(candidate(rule, file, modified: modified))
            }
        }
        return out.sortedForDisplay(by: .size)
    }

    private static func candidate(_ rule: SystemLevelRule, _ file: SpaceNode, modified: Double) -> JunkCandidate {
        JunkCandidate(
            ruleID: rule.id,
            group: .systemLevel,
            title: file.name,
            path: file.path,
            tier: .safe,
            bytes: file.accountedBytes,
            fileCount: file.fileCount,
            isPartial: file.isPartial,
            allReclaimableAccounting: file.allReclaimableAccounting,
            rationale: rule.rationale,
            symbolName: rule.symbolName,
            // 文件自身的修改时间:「按新旧」排序用;删前复核的快照也取它(文件节点没有
            // 目录自身 mtime 那一项,扫描引擎只给文件填 newestChangeEpoch)。
            newestChangeEpoch: modified,
            modifiedAtScan: modified,
            flags: [.requiresAuthorization]
        )
    }
}
