import SwiftUI

@main
struct PulseApp: App {
    /// 菜单栏常驻入口:系统 CPU 负载数字(现为硬编码假数据),点击打开组榜弹窗。
    var body: some Scene {
        MenuBarExtra {
            DashboardView()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "waveform.path.ecg")
                Text(PulseFormat.cpuPercent(FakeSnapshot.systemCPULoad))
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
