import Foundation

/// 清理扫描的路径域判定(arch-clean/02:从 Live 枚举器挪来的领域规则)。
public enum CleanPathDomain {
    /// 用户域(可能收到 TCC 拒绝、全盘访问可解的):家目录之下——扫描喂进来的是
    /// 物理路径(/System/Volumes/Data/Users/…),兼容两域判断。用户域的 EPERM 才
    /// 引导授权;系统域的 EPERM 是 root / 系统保护,全盘访问也无解。
    public static func isUserDomain(_ path: String) -> Bool {
        path.hasPrefix("/Users/") || path.hasPrefix(SpaceMapTree.dataVolumePath + "/Users/")
    }
}
