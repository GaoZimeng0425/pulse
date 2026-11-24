import Foundation
import PulseCore

/// launchd plist 目录的真实读取(launchd-attribution/01,ADR-0005):FileManager 枚举目录、
/// 读每个 `.plist` 的字节;缺席 / 不可读 / 有内容三种结果交给 PulseCore 的缝上判定。
/// 不解析、不解符号链接——那两件事在 `LaunchdManifestAssembler` 里,包内可测。
struct LiveLaunchdPlistSource: LaunchdPlistSource {
    func read(directory: String) -> LaunchdPlistDirectoryRead {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .absent
        }
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return .unreadable
        }
        let plists = names
            .filter { $0.hasSuffix(".plist") }
            .compactMap { fileManager.contents(atPath: directory + "/" + $0) }
        return .plists(plists)
    }
}
