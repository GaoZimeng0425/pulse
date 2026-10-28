import AppKit
import Foundation
import PulseCore

// MARK: - Live 废纸篓执行器(p4-cleaner/04)

//
// `CleanTrashExecutor` 的真实现(ADR-0008:全系统唯二的删除出口,只许这两种模式)。
// 移入废纸篓走 NSWorkspace.recycle——探针 12(docs/probes/12-trash-structure)实测:吃 [URL],
// 回调回赠 原 URL → 废纸篓内 URL 字典,文件与目录都 OK,Finder 可恢复;本机唯一废纸篓是
// ~/.Trash(启动卷密封、无 /.Trashes;外置卷 .Trashes/<uid> 场景探针留档待补测)。
// 逐项调用而不是一批:recycle 的 error 是整批一个,逐项调才能把"哪一项为什么失败"如实报
// 到确认结果与清理历史里(票面:失败项如实报)。
// 清空废纸篓(emptyTrash)按 spec 直删用户可写的废纸篓内容;UI 入口与真机验证归 08 票,
// 本票只交付协议履约,不接按钮。

struct LiveCleanTrashExecutor: CleanTrashExecutor {
    func recycleToTrash(_ paths: [String]) async -> TrashRecycleOutcome {
        var outcome = TrashRecycleOutcome()
        for path in paths {
            switch await recycleOne(URL(fileURLWithPath: path)) {
            case let .success(destination?):
                outcome.recycled[path] = destination.path
            case .success(nil):
                // 系统说成功却没给去向:不敢当成功记(历史里写不出"去哪了"),按失败如实报。
                outcome.failures[path] = "系统未返回废纸篓去向"
            case let .failure(error):
                outcome.failures[path] = error.localizedDescription
            }
        }
        return outcome
    }

    /// NSWorkspace 是 AppKit 主线程 API:跳主 actor 发起,回调里恢复 continuation。
    private func recycleOne(_ url: URL) async -> Result<URL?, any Error> {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSWorkspace.shared.recycle([url]) { newURLs, error in
                    if let error {
                        continuation.resume(returning: .failure(error))
                    } else {
                        continuation.resume(returning: .success(newURLs.first?.value))
                    }
                }
            }
        }
    }

    /// 清空用户可写的全部废纸篓:~/.Trash 与各卷 .Trashes/<uid>。逐项删顶层条目,无权限 /
    /// 失败项跳过并计数(不中断、不伪造)。字节按删除前 FileManager 的分配大小求和
    /// (这里不是「实际占用」口径——废纸篓里克隆的真实可释放量没必要精算,文案按"约"报)。
    func emptyTrash() async -> TrashEmptySummary {
        var volumes: [TrashVolumeEmptySummary] = []
        for (volume, directory) in Self.userTrashDirectories() {
            var emptied = 0, skipped = 0
            var freed: Int64 = 0
            let manager = FileManager.default
            guard let entries = try? manager.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for name in entries where name != ".DS_Store" {
                let itemPath = (directory as NSString).appendingPathComponent(name)
                let size = Self.allocatedSize(atPath: itemPath)
                do {
                    try manager.removeItem(atPath: itemPath)
                    emptied += 1
                    freed += size
                } catch {
                    skipped += 1
                }
            }
            volumes.append(TrashVolumeEmptySummary(
                volume: volume,
                emptiedItems: emptied,
                freedBytes: freed,
                skippedItems: skipped
            ))
        }
        return TrashEmptySummary(volumes: volumes)
    }

    /// (卷名, 废纸篓目录)。启动卷 = ~/.Trash;其余 = /Volumes/*/.Trashes/<uid>(存在才列)。
    private static func userTrashDirectories() -> [(String, String)] {
        var result = [("启动卷", NSHomeDirectory() + "/.Trash")]
        let uid = getuid()
        if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for volume in volumes {
                let candidate = "/Volumes/\(volume)/.Trashes/\(uid)"
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                    result.append((volume, candidate))
                }
            }
        }
        return result
    }

    private static func allocatedSize(atPath path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        var total: Int64 = 0
        if let values = try? url.resourceValues(forKeys: keys), values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        for case let child as URL in enumerator {
            if let size = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }
}
