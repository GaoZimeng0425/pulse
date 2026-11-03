import Foundation
import PulseCore

/// 扫描结果落盘缓存(p4-cleaner/11):一个文件、整读整写,编码在 PulseCore
/// `SpaceScanCache`。读写经注入闭包隔离(测试注入临时目录 / 内存闭包);
/// 生产文件 `~/.Pulse/scan-cache-v1.bin`(与日志、历史库同住 app 数据目录)。
/// 损坏/不识别 → load 返回 nil(界面回空态,绝不半解半猜);写失败只记日志,
/// 不影响扫描流程本身。
struct CleanScanResultStore: Sendable {
    static let productionFileName = "scan-cache-v1.bin"

    let load: @Sendable () -> SpaceScanCachePayload?
    let save: @Sendable (SpaceScanCachePayload) -> Void

    /// 生产构造:app 数据目录(~/.Pulse)下单文件。
    init?(directory: URL? = nil) {
        let dir = directory ?? URL(
            fileURLWithPath: NSString(string: "~/.Pulse").expandingTildeInPath,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            LogService.error("扫描缓存目录创建失败:\(error)", category: "Cleaner")
            return nil
        }
        let fileURL = dir.appendingPathComponent(Self.productionFileName)
        load = { [fileURL] in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            guard let payload = SpaceScanCache.decode(data) else {
                LogService.warn("扫描缓存不可读(损坏或版本不识别),忽略", category: "Cleaner")
                return nil
            }
            return payload
        }
        save = { [fileURL] payload in
            do {
                try SpaceScanCache.encode(payload).write(to: fileURL, options: .atomic)
            } catch {
                LogService.error("扫描缓存写入失败:\(error)", category: "Cleaner")
            }
        }
    }

    /// 注入闭包的构造(测试:临时文件 / 内存闭包)。
    init(
        load: @escaping @Sendable () -> SpaceScanCachePayload?,
        save: @escaping @Sendable (SpaceScanCachePayload) -> Void
    ) {
        self.load = load
        self.save = save
    }
}
