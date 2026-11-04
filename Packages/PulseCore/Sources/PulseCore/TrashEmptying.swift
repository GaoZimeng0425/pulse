import Foundation

// MARK: - 清空废纸篓(p4-uninstaller/04,自 p4-cleaner/08 摘出提前;Q3 腾空间闭环)

//
// Live 的删除本体一期已交付(LiveCleanTrashExecutor.emptyTrash:多卷发现 + 逐项
// 删 + 失败跳过计数)。本文件补三件纯值:
//   1) TrashInventory——清点(确认文案的数字来源:项数 / 约多少空间 / 哪些卷);
//   2) isInsideTrash——防御闸(ADR-0008:清空的删除动作只许落在废纸篓目录内的
//      条目上;Live 侧在删除前 guard,越界按跳过计,绝不出废纸篓一步);
//   3) confirmationText——普通二次确认的文案(票面三条:所有卷汇总、永久删除
//      不可恢复、包括其他 App 扔进废纸篓的内容)。
// 历史不记:清的是「已在废纸篓里的东西」,不是本次清理动作的产物,且项数可能
// 巨大(整目录 app);磁盘释放由磁盘卡数字自然呈现(Q10 同款口径)。
// 字节口径:Live 用分配大小求和,不是「实际占用」——废纸篓里克隆的真实可释放
// 量没必要精算,文案按「约」报。

/// 废纸篓清点结果(点按钮时现点,数字进确认弹窗)。
public struct TrashInventory: Sendable, Equatable {
    public struct Volume: Sendable, Equatable, Identifiable {
        public var id: String {
            name
        }

        /// 卷名(启动卷 / 外置卷名,Live 的发现逻辑给定)。
        public let name: String
        public let items: Int
        /// 分配大小求和(约数,同文件头口径注记)。
        public let bytes: Int64

        public init(name: String, items: Int, bytes: Int64) {
            self.name = name
            self.items = items
            self.bytes = bytes
        }
    }

    public let volumes: [Volume]

    public init(volumes: [Volume]) {
        self.volumes = volumes
    }

    public var totalItems: Int {
        volumes.reduce(0) { $0 + $1.items }
    }

    public var totalBytes: Int64 {
        volumes.reduce(0) { $0 + $1.bytes }
    }

    public var isEmpty: Bool {
        totalItems == 0
    }
}

public enum TrashEmptying {
    /// 防御闸:路径必须落在某个废纸篓目录**之内**(组件前缀,不是裸字符串前缀
    /// ——"/Users/x/.TrashOld" 会被 "/Users/x/.Trash" 的裸 hasPrefix 误中,同
    /// AppCatalog.isRunning 的坑)。Live 删除循环逐条 guard,越界按跳过计。
    public static func isInsideTrash(_ path: String, trashDirectories: [String]) -> Bool {
        trashDirectories.contains { directory in
            path == directory || path.hasPrefix(directory + "/")
        }
    }

    /// 确认弹窗正文(票面三条全含;多卷时逐卷报数,单卷不列卷名凑字)。
    public static func confirmationText(for inventory: TrashInventory) -> String {
        var text = "将清空所有卷的废纸篓,共 \(inventory.totalItems) 项 · 约 \(byteText(inventory.totalBytes))"
        if inventory.volumes.count > 1 {
            let parts = inventory.volumes
                .filter { $0.items > 0 }
                .map { "\($0.name) \($0.items) 项" }
            if !parts.isEmpty {
                text += "(\(parts.joined(separator: " · ")))"
            }
        }
        text += "。这是永久删除,不可恢复——包括其他 App 扔进废纸篓的内容。"
        return text
    }

    static func byteText(_ bytes: Int64) -> String {
        PulseFormat.diskCapacity(UInt64(max(0, bytes)))
    }
}
