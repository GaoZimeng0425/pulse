import AppKit
import PulseCore
import SwiftUI

// MARK: - 传感器页派生读数卡 AppKit 版(popover-appkit/05)

/// 派生读数卡紧凑档(SmcDerivedCardView 同值):副卡头「派生读数」+ 注记「N 个命名传感器
/// 在场」/ Average·Hottest × CPU·GPU·SoC 六行 + 最快风扇行(行距 6)。弹窗传感器页唯一
/// 的卡(p2-review/04 A 拍板例外:风扇卡与温度明细不进弹窗)。温度 meter 按 110°C 恒定域
/// 归一;风扇 meter 按该扇上下限归一;文案规则见 DESIGN.md「传感器卡文案与风扇条」。
@MainActor
final class SmcDerivedCardNSView: ObservingView {
    private static let scaleMax = 110.0

    private let reading: @MainActor () -> SmcReading?
    private let tint = Metric.sensors.accentColor.ns
    private let header: CardSubHeaderView
    private let rowsStack = vstack([], spacing: 6)
    private let rows: [MeterDetailRowView]
    private let empty = EmptyStateView()

    init(reading: @escaping @MainActor () -> SmcReading?) {
        self.reading = reading
        header = CardSubHeaderView(symbolName: "thermometer.medium", title: "派生读数", tint: tint)
        rows = (0 ..< 7).map { _ in
            MeterDetailRowView(labelWidth: CardRowWidth.label, valueMinWidth: CardRowWidth.temperatureValue)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            rowsStack.addArrangedSubview(row)
            row.fillWidth(of: rowsStack)
        }
        empty.set(title: "传感器暂不可用")
        let card = makeDetailCard([header, rowsStack, empty])
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let reading = reading()
        header.setNote(reading.map { "\($0.knownTemps.count) 个命名传感器在场" })
        rowsStack.isHidden = reading == nil
        empty.isHidden = reading != nil
        guard let reading else { return }
        let derived = reading.derived
        let temps: [(String, Double?)] = [
            ("CPU 均值", derived.cpuAverage),
            ("CPU 最热", derived.cpuHottest),
            ("GPU 均值", derived.gpuAverage),
            ("GPU 最热", derived.gpuHottest),
            ("SoC 均值", derived.socAverage),
            ("SoC 最热", derived.socHottest),
        ]
        for (row, (title, value)) in zip(rows, temps) {
            row.set(
                title: title,
                fraction: value.map { min(max($0 / Self.scaleMax, 0), 1) } ?? 0,
                value: value.map { String(format: "%.1f°C", $0) } ?? "—",
                tint: tint
            )
        }
        // 最快风扇行:无风扇 / 全读不到 → "—"(不伪造 0 rpm);多扇时数值前带扇名。
        let fan = reading.fastestFan
        let fanText = fan.map { fan in
            reading.fans.count > 1
                ? "\(PopoverFanText.title(fan)) · \(PopoverFanText.speed(fan))"
                : PopoverFanText.speed(fan)
        } ?? "—"
        rows[6].set(title: "最快风扇", fraction: fan?.speedFraction ?? 0, value: fanText, tint: tint)
    }
}

/// 风扇文案(SmcCardViews.swift `SmcFanText` 的同文副本——原版为 private,主窗口视图
/// 本期不动;两处口径一起改)。
enum PopoverFanText {
    /// 扇名:SMC F?ID 原文,读不到用"风扇 N"(序号从 1 数)。
    static func title(_ fan: SmcFanReading) -> String {
        fan.name ?? "风扇 \(fan.id + 1)"
    }

    /// 转速:rpm 0 是真读数,写"停转"而非"0 rpm"(DESIGN.md 传感器卡文案)。
    static func speed(_ fan: SmcFanReading) -> String {
        fan.rpm == 0 ? "停转" : "\(fan.rpm) rpm"
    }
}
