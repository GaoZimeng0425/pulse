import Foundation

// MARK: - 特权助手门槛四态(energy-gate-fix,2026-11-22)

//
// 为什么不直接用 SMAppService 三态:用户实案——Pulse 更新换 bundle 后,
// BTM(后台任务管理)残留旧条目的 enabled 判定,新 helper 从未批准也从未
// 跑起,卡片照着 status 显示「特权助手运行中」骗用户干等。macOS 的安全
// 设计如此:守护进程按**内容指纹**批准,每次构建指纹变 = 视为新后台项,
// 必须用户重新点头(p3 时代 plist 运维注释已记;与签名身份无关——自签稳定
// 解决的是 TCC 层,两层口径不同)。
// 融合物理真值:系统说 enabled + 拉取持续失败 = 没在运行,说实话并给
// 「重新登记」出口。纯值函数,PulseTests 钉四态。

/// 特权助手门槛四态(电池页耗电排行两卡的空态判据)。
enum EnergyHelperGate: Equatable {
    /// 未安装(设置开关没开)。
    case notInstalled
    /// 已提交注册,等用户在 系统设置 → 通用 → 登录项与扩展 批准。
    case awaitingSystemApproval
    /// 系统说已批准,但助手拉取持续失败——实际没在运行(换 bundle 未重登 /
    /// BTM 旧代残留)。要说实话并给重新登记出口,不假称运行中。
    case approvedButNotRunning
    /// 已批准且拉取健康,首档读数尚未到达(60s 节拍)。
    case approvedAwaitingReading

    static func resolve(status: PrivilegedHelperStatus, fetchFailing: Bool) -> EnergyHelperGate {
        switch status {
        case .notRegistered:
            .notInstalled
        case .requiresApproval:
            .awaitingSystemApproval
        case .enabled:
            fetchFailing ? .approvedButNotRunning : .approvedAwaitingReading
        }
    }
}
