import AppKit
import PulseCore
import SwiftUI

// MARK: - 外设页卡片 AppKit 版(popover-appkit/05):蓝牙设备卡 + 声音卡

/// 蓝牙设备卡紧凑档(BluetoothDevicesCardView 同值):副卡头「蓝牙」(注记只在 ready 态给
/// 「N 台设备 · M 台已连接」)/ 授权三态各一句话 + `.link` 动作(开启 / 授权 / 打开系统设置,
/// 按钮就是系统弹窗出现的那一刻,被拒绝不自动重试)/ ready 态每台一行(前 6 台,行距 6)。
@MainActor
final class BluetoothDevicesCardNSView: ObservingView {
    private static let visibleLimit = 6

    private let feature: BluetoothFeature
    private let tint = Metric.bluetooth.accentColor.ns
    private let header: CardSubHeaderView
    private let rowsStack = vstack([], spacing: 6)
    private var rows: [BluetoothDeviceRowView] = []
    private let empty = EmptyStateView()
    private var shownState: BluetoothAccessState?
    private var shownNoDevices: Bool?

    init(feature: BluetoothFeature) {
        self.feature = feature
        header = CardSubHeaderView(symbolName: "antenna.radiowaves.left.and.right", title: "蓝牙", tint: tint)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = makeDetailCard([header, rowsStack, empty])
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let state = feature.accessState
        let devices = feature.reading?.devices ?? []
        header.setNote(state == .ready ? note(devices) : nil)
        let showsRows = state == .ready && !devices.isEmpty
        rowsStack.isHidden = !showsRows
        empty.isHidden = showsRows
        if showsRows {
            let visible = Array(devices.prefix(Self.visibleLimit))
            syncRows(&rows, count: visible.count, in: rowsStack) { BluetoothDeviceRowView(tint: tint) }
            for (row, device) in zip(rows, visible) {
                row.set(device)
            }
        } else if shownState != state || shownNoDevices != devices.isEmpty {
            setEmpty(state)
        }
        shownState = state
        shownNoDevices = devices.isEmpty
    }

    private func note(_ devices: [BluetoothDeviceRow]) -> String? {
        guard !devices.isEmpty else { return nil }
        let connected = devices.filter(\.isConnected).count
        return "\(devices.count) 台设备 · \(connected) 台已连接"
    }

    private func setEmpty(_ state: BluetoothAccessState) {
        switch state {
        case .disabled:
            empty.set(
                title: "蓝牙监控未开启",
                detail: "开启后读取已配对设备的连接状态与电量;首次会请求一次蓝牙权限,只在你点击时弹出",
                actionTitle: "开启蓝牙监控",
                action: { [feature] in feature.setEnabled(true) }
            )
        case .needsAuthorization:
            empty.set(
                title: "需要蓝牙权限",
                detail: "系统尚未确认(应用更新后会重新询问);授权框只在你点击时弹出",
                actionTitle: "授权蓝牙",
                action: { [feature] in feature.requestAuthorization() }
            )
        case .denied:
            empty.set(
                title: "蓝牙权限已拒绝",
                detail: "在 系统设置 › 隐私与安全性 › 蓝牙 里允许 Pulse,回到这里自动恢复;Pulse 不会反复请求",
                actionTitle: "打开系统设置",
                action: Self.openBluetoothPrivacySettings
            )
        case .ready:
            empty.set(title: "蓝牙不可用或无设备")
        }
    }

    /// 隐私面板深链(与 BluetoothDevicesCardView 同一 anchor:Privacy_Bluetooth)。
    private static func openBluetoothPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// 蓝牙设备行(间距 8):6pt 连接点(已连接 = 蓝牙色,否则 inactive)+ 名称(12 medium)
/// + 弹性空白(≥8)+ 电量条(紧凑 44)与百分比(≥36)或「电量未知」(11 tertiary)
/// + RSSI(≥32,tertiary)。
@MainActor
final class BluetoothDeviceRowView: NSStackView {
    private let tint: NSColor
    private let dot = DotView(diameter: 6)
    private let nameLabel = makeNameLabel()
    private let meter = MeterBarView(width: CardRowWidth.meterCompact)
    private let percentLabel = makeRowValue(minWidth: CardRowWidth.percentValue)
    private let unknownLabel = makeLabel("电量未知", font: PFont.text(11), color: Ink.tertiary)
    private let rssiLabel = makeRowValue(minWidth: CardRowWidth.rssiValue, color: Ink.tertiary)

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        alignment = .centerY
        distribution = .fill
        translatesAutoresizingMaskIntoConstraints = false
        meter.tint = tint
        unknownLabel.setContentHuggingPriority(.required, for: .horizontal)
        unknownLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [dot, nameLabel, spacer(minLength: 8), meter, percentLabel, unknownLabel, rssiLabel] {
            addArrangedSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ device: BluetoothDeviceRow) {
        let dotColor = device.isConnected ? tint : DetailInk.inactive
        if dot.color != dotColor {
            dot.color = dotColor
        }
        nameLabel.setText(device.name)
        let percent = device.batteryPercent
        meter.isHidden = percent == nil
        percentLabel.isHidden = percent == nil
        unknownLabel.isHidden = percent != nil
        if let percent {
            meter.fraction = min(max(Double(percent) / 100, 0), 1)
            percentLabel.setText("\(percent)%")
        }
        rssiLabel.setText(device.rssi.map { "\($0) dBm" } ?? "—")
    }
}

/// 声音卡紧凑档(SoundCardView 同值):副卡头「声音」(注记 = 静音 / 音量%)/ 设备名
/// (12 medium)+ 音量行(行距 6);无设备安静占位。纯展示,不做控制。
@MainActor
final class SoundCardNSView: ObservingView {
    private let reading: @MainActor () -> SoundReading?
    private let tint = Metric.sound.accentColor.ns
    private let header: CardSubHeaderView
    private let deviceLabel = makeNameLabel()
    private let speaker = NSImageView()
    private let meter = MeterBarView()
    private let percentLabel = makeRowValue(minWidth: CardRowWidth.percentValue)
    private let fixedLabel = makeLabel("设备不控音量", font: PFont.text(12), color: Ink.tertiary)
    private let deviceStack: NSStackView
    private let empty = EmptyStateView()
    private var shownMuted: Bool?

    init(reading: @escaping @MainActor () -> SoundReading?) {
        self.reading = reading
        header = CardSubHeaderView(symbolName: "speaker.wave.2.fill", title: "声音", tint: tint)
        speaker.translatesAutoresizingMaskIntoConstraints = false
        speaker.setContentHuggingPriority(.required, for: .horizontal)
        speaker.setContentCompressionResistancePriority(.required, for: .horizontal)
        meter.tint = tint
        let volumeRow = makeDetailRow([speaker, meter, percentLabel, fixedLabel])
        deviceStack = vstack([deviceLabel, volumeRow], spacing: 6)
        volumeRow.fillWidth(of: deviceStack)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        empty.set(title: "暂无输出设备")
        let card = makeDetailCard([header, deviceStack, empty])
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let reading = reading()
        header.setNote(note(reading))
        guard let reading, let name = reading.deviceName, !name.isEmpty else {
            deviceStack.isHidden = true
            empty.isHidden = false
            return
        }
        deviceStack.isHidden = false
        empty.isHidden = true
        deviceLabel.setText(name)
        let muted = reading.isMuted == true
        if shownMuted != muted {
            shownMuted = muted
            speaker.image = symbolImage(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 11)
            speaker.contentTintColor = muted ? Ink.secondary : tint
        }
        let percent = reading.volumePercent
        meter.isHidden = percent == nil
        percentLabel.isHidden = percent == nil
        fixedLabel.isHidden = percent != nil
        if let percent {
            meter.fraction = min(max(percent / 100, 0), 1)
            percentLabel.setText("\(Int(percent.rounded()))%")
        }
    }

    private func note(_ reading: SoundReading?) -> String? {
        guard let reading else { return nil }
        if reading.isMuted == true {
            return "静音"
        }
        return reading.volumePercent.map { "\(Int($0.rounded()))%" }
    }
}
