import Foundation

/// 路径轻量归一(评审 T4,共享助手):去掉尾部 "/"(根路径 "/" 除外),
/// 不做任何文件系统访问。项目根存储(ProjectRootsStore)的持久化去重与
/// 归组引擎(GroupingEngine)的项目根前缀匹配共用这一份口径——
/// 此前两处各写一份行为相同的实现。
public enum PathNormalization {
    public static func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
