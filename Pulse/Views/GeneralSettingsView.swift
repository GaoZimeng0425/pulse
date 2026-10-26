import AppKit
import PulseCore
import ServiceManagement
import SwiftUI

/// 通用设置(2026-10-16,用户反馈"开机自启这类设置应该进 Settings"):
/// 登录自启 + 日志入口 + 版本信息。设置窗由此从单一"项目根"扩为
/// 标准多标签形态;P1 再入菜单徽标配置等。
///
/// 登录自启以**系统登录项为唯一事实来源**(SMAppService.mainApp,无需
/// UserDefaults 双份账本):开关动作即时注册/注销,窗口出现时从系统读回;
/// 开关状态与系统真实状态解耦(程序性回滚不重触发动作,见 syncing 注释)。
struct GeneralSettingsView: View {
    /// 采样管线(工单 11):诊断报告的统计数据源(运行起点/轮数/均值/峰值)。
    let monitor: SystemMonitor

    /// 系统登录项状态的镜像;程序性赋值(读回/失败回滚)前置 suppress 标记,
    /// 防止镜像变化再次触发 onChange 造成重入。
    @State private var launchAtLogin = false
    @State private var requiresApproval = false
    @State private var notInstalledNotice: String?
    @State private var suppressNextChange = false
    /// 复制反馈(工单 11):标签翻转"已复制",~2s 后复位;新点击先取消旧定时,
    /// 连点不会提前收走反馈。
    /// 特权助手(p3-root-mcp/03)三态镜像:与登录项同款"系统是唯一事实源"
    /// 模式——开关动作即时 register/unregister,显示从 SMAppService 读回。
    @State private var helperStatus: PrivilegedHelperStatus = .notRegistered
    @State private var helperSuppressNextChange = false
    @State private var reportCopied = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .disabled(notInstalledNotice != nil)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if suppressNextChange {
                            suppressNextChange = false
                            return
                        }
                        applyLaunchAtLogin(enabled)
                    }
                if let notInstalledNotice {
                    Text(notInstalledNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if requiresApproval {
                    approvalHint
                }
            }
            // 授权型能力默认关、开关是唯一触发源(权限原则,CODING_STANDARDS
            // 「权限 / TCC 纪律」):开的那一刻才可能弹系统蓝牙权限框。
            Section("外设") {
                Toggle("蓝牙外设监控", isOn: Binding(
                    get: { monitor.bluetooth.isEnabled },
                    set: { monitor.bluetooth.setEnabled($0) }
                ))
                Text("读取已配对设备的连接状态与电量。开启时请求一次蓝牙权限,只在你操作时弹出;关闭则完全不读取蓝牙。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("特权助手") {
                Toggle("能耗归因(Root 助手)", isOn: Binding(
                    get: { helperStatus == .enabled },
                    set: { enabled in
                        if helperSuppressNextChange {
                            helperSuppressNextChange = false
                            return
                        }
                        PrivilegedHelperStatus.setInstalled(enabled)
                        refreshHelperStatus()
                    }
                ))
                switch helperStatus {
                case .enabled:
                    Text("助手以 root 运行中:每分钟采集一次各 App 能耗影响,历史页可看全机合计。关闭即注销,一步干净。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .requiresApproval:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已提交注册,等你批准:在 系统设置 → 通用 → 登录项与扩展 中允许 Pulse 的后台项(需 Touch ID/密码)。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("打开系统设置") { openLoginItemsPane() }
                            .buttonStyle(.link)
                    }
                case .notRegistered:
                    Text("开启将安装一个仅采集能耗影响的 root 后台助手(首次需系统授权一次);不开启则完全不存在。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("诊断") {
                LabeledContent("文件日志") {
                    Button("打开日志文件夹") { openLogsFolder() }
                }
                Text("位于 ~/.Pulse/logs,最多保留 14 个文件自动轮转。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("诊断报告") {
                    Button(reportCopied ? "已复制" : "复制诊断报告") { copyDiagnosticReport() }
                }
                Text("版本 / 系统 / 机型 / 采样统计 / 最近日志尾部拼成纯文本,报 bug 时直接粘贴。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("关于") {
                LabeledContent("版本", value: versionText)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
        .padding()
        .onAppear {
            refreshLaunchAtLogin()
            refreshHelperStatus()
        }
    }

    /// 系统要求用户手动批准(SMAppService 注册后可能落到 requiresApproval)。
    private var approvalHint: some View {
        HStack {
            Text("系统需要你手动批准:在 系统设置 → 通用 → 登录项 中允许 Pulse 在后台运行。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("打开系统设置") { openLoginItemsPane() }
                .buttonStyle(.link)
        }
    }

    /// 从系统登录项读回真实状态。
    private func refreshLaunchAtLogin() {
        notInstalledNotice = nil
        // 登录项指向**当前运行副本**的路径:开发期从 build/ 临时目录运行时,
        // 注册会把登录项钉在会被覆盖/清除的构建产物上——直接禁用并说明。
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            notInstalledNotice = "当前副本运行自构建目录("
                + Bundle.main.bundlePath
                + "),登录项会指向构建产物。请先用 sh scripts/build.sh 安装到 /Applications 再开启。"
            return
        }
        let status = SMAppService.mainApp.status
        setSystemMirror(status == .enabled)
        requiresApproval = (status == .requiresApproval)
    }

    /// 开关动作:注册/注销 + 留痕;失败回滚镜像到系统真实状态。
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                LogService.info("登录自启已注册", category: "Settings")
            } else {
                try SMAppService.mainApp.unregister()
                LogService.info("登录自启已取消", category: "Settings")
            }
        } catch {
            LogService.error("登录自启切换失败:\(error.localizedDescription)", category: "Settings")
            setSystemMirror(!enabled) // 回滚到系统事实
        }
        requiresApproval = (SMAppService.mainApp.status == .requiresApproval)
    }

    /// 镜像赋值统一走这里:变化时挂 suppress,吃掉镜像引发的 onChange。
    private func setSystemMirror(_ value: Bool) {
        guard launchAtLogin != value else { return }
        suppressNextChange = true
        launchAtLogin = value
    }

    /// 特权助手状态读回(镜像统一走 suppress,与登录项同款防重入)。
    private func refreshHelperStatus() {
        let status = PrivilegedHelperStatus.current()
        helperSuppressNextChange = true
        helperStatus = status
    }

    private func openLoginItemsPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openLogsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: LogService.logDirectory))
    }

    /// 一键复制诊断报告(工单 11):拼装是纯函数(时钟/统计/日志尾全部注入,
    /// 单测见 DiagnosticReportTests),这里只做取数与剪贴板写入;成功反馈 =
    /// 按钮标签翻转"已复制"约 2 秒。
    private func copyDiagnosticReport() {
        let monitor = monitor
        Task {
            let report = await DiagnosticReport.assemble(
                version: bundleValue("CFBundleShortVersionString"),
                build: bundleValue("CFBundleVersion"),
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                chipName: HostInfo.current.chipName,
                stats: monitor.samplingStats(),
                logTail: DiagnosticReport.logTail(directory: LogService.logDirectory),
                now: Date()
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            LogService.info("诊断报告已复制(\(report.count) 字符)", category: "Settings")

            copyFeedbackTask?.cancel()
            reportCopied = true
            copyFeedbackTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                reportCopied = false
            }
        }
    }

    /// Info.plist 字符串读取,缺失以 "?" 兜底(与 versionText 同口径)。
    private func bundleValue(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "?"
    }

    private var versionText: String {
        "\(bundleValue("CFBundleShortVersionString")) (\(bundleValue("CFBundleVersion")))"
    }
}

// MARK: - 预览(arch-review-2026-10-18/02:预览缺口补齐;登录项只读不写)

#Preview("通用设置") {
    GeneralSettingsView(monitor: .preview())
        .frame(width: 480, height: 420)
}
