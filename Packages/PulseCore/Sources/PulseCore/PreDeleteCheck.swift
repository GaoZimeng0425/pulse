import Foundation

// MARK: - 删前复核(p5-cleaner/03,spec §15:全清理统一,执行层一道)

//
// 在用重查之外的独立第二道闸,问的是「扫描(或残留探测)之后,它被动过没有」:
// 目标仍存在 + 条目自身 mtime 与快照一致,才交给执行器;否则该项跳过,原因人话进
// 结果卡失败清单与清理历史(如实报,不默认成功,也不悄悄吞掉)。
//
// 口径:
// - 只比条目自身 mtime(目录里增删改名条目就变;深处文件内容改动不在此列——那是
//   另一种成本的复核,spec 拍板只做这一层)。一次 lstat,不重走子树。
// - 容差 1µs:扫描与探针同一公式换算(`FsTimestamp.epoch`),本应逐位相等;容差只防
//   表示层意外,吞不掉真实变动——变动把 mtime 改成「现在」,与快照至少差出两步之间
//   流逝的时间(秒级以上)。
// - 无快照 / 读不到 = 跳过(fail-closed):无快照的条目来自旧版缓存,恰恰最可能已经变了;
//   读不到状态就证明不了没变。
//
// 参考纪律:Mole 删前 inode 快照、purrge「扫描后未修改」复核——机制互证,零搬码。

public enum PreDeleteCheck {
    public enum Verdict: Sendable, Equatable {
        case unchanged
        case changed
        case missing
        case noSnapshot
        case unreadable
    }

    /// 快照出自哪一步(只影响人话里的「扫描 / 列出」与重试建议)。
    public enum Origin: Sendable, Equatable {
        /// 清理清单:扫描树上的目录自身 mtime。
        case scan
        /// 卸载残留:展开应用时探测到的条目自身 mtime。
        case leftoverProbe
    }

    static let tolerance: Double = 1e-6

    public static func verdict(snapshot: Double?, current: PathSnapshot) -> Verdict {
        switch current {
        case .missing:
            return .missing
        case .unreadable:
            return .unreadable
        case let .present(modified):
            guard let snapshot else { return .noSnapshot }
            return abs(modified - snapshot) <= tolerance ? .unchanged : .changed
        }
    }

    /// 跳过原因(nil = 通过)。进结果卡失败清单与清理历史,用户读得懂、知道下一步做什么。
    public static func skipReason(_ verdict: Verdict, origin: Origin) -> String? {
        switch (verdict, origin) {
        case (.unchanged, _):
            nil
        case (.changed, .scan):
            "扫描后目录有变动,已跳过——重新扫描后再清"
        case (.changed, .leftoverProbe):
            "列出残留后它有变动,已跳过——重新打开该应用的残留清单后再卸载"
        case (.missing, .scan):
            "扫描后目录已不在原处(可能已被删除或移走),已跳过"
        case (.missing, .leftoverProbe):
            "列出残留后它已不在原处(可能已被删除或移走),已跳过"
        case (.noSnapshot, .scan):
            "缺少扫描快照(结果来自旧版扫描),无法确认扫描后没动过,已跳过——重新扫描后再清"
        case (.noSnapshot, .leftoverProbe):
            "缺少探测快照,无法确认列出后没动过,已跳过——重新打开该应用的残留清单后再卸载"
        case (.unreadable, .scan):
            "此刻读不到目录状态,无法确认扫描后没动过,已跳过"
        case (.unreadable, .leftoverProbe):
            "此刻读不到它的状态,无法确认列出后没动过,已跳过"
        }
    }

    /// 逐项复核,分成「放行」与「跳过(路径 → 原因)」。放行项保持输入顺序。
    public static func partition<Item>(
        _ items: [Item],
        path: (Item) -> String,
        snapshot: (Item) -> Double?,
        origin: Origin,
        currentState: (String) async -> PathSnapshot
    ) async -> (cleared: [Item], skipped: [String: String]) {
        var cleared: [Item] = []
        var skipped: [String: String] = [:]
        for item in items {
            let itemPath = path(item)
            let current = await currentState(itemPath)
            if let reason = skipReason(verdict(snapshot: snapshot(item), current: current), origin: origin) {
                skipped[itemPath] = reason
            } else {
                cleared.append(item)
            }
        }
        return (cleared, skipped)
    }
}
