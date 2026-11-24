import Foundation

// MARK: - 蓝牙授权(权限原则:默认关 + 用户动作处才弹 + 静默预检 + 被拒不重试)

/// 进程级蓝牙授权态(`CBManagerAuthorization` 的镜像)。IOBluetooth 与 CoreBluetooth
/// 走同一个 TCC 服务,一个读数覆盖三源。不直接用 CoreBluetooth 类型,是让功能模块
/// 与单测不依赖蓝牙栈。
public enum BluetoothAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case allowed
}

/// 蓝牙授权的两个动作必须分清(CODING_STANDARDS「权限 / TCC 纪律」):
/// - `authorization()` **静默**:只读类属性,不初始化协调器、不弹窗——启动路径、
///   可见性切换、回前台都可以调;
/// - `requestAccess` **显式**:全 app 唯一会触发系统蓝牙权限弹窗的调用,只许在用户
///   动作(设置开关 / 卡片按钮)那一刻调用;系统有答复后回调一次,用户不答复不回调。
public protocol BluetoothAccessControl: Sendable {
    func authorization() -> BluetoothAuthorization
    func requestAccess(_ completion: @escaping @Sendable () -> Void)
}
