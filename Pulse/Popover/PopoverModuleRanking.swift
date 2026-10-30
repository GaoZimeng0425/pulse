import AppKit
import PulseCore
import SwiftUI

// MARK: - 模块排行卡 AppKit 版(popover-appkit/03;ModuleRankingCardView 紧凑档)

/// 只读模块排行(能耗影响 / AI 助手 / 读写最多 / 每进程流量):与组排行同一卡壳与行
/// 排版,无悬停、不可展开、无结束入口,行尾列留空占位(meter / 数值同一竖线)。
/// 行按位置复用,行数变化才增删;卡底注脚声明数据节拍。
@MainActor
final class ModuleRankingCardNSView: ObservingView {
    private static let defaultEmpty = RankingEmptyMessage(title: "暂无数据", detail: "本页可见并完成首档采样后出数")

    private let rowsProvider: @MainActor () -> [ModuleRankingRow]
    private let accent: Color
    private let emptyMessage: RankingEmptyMessage
    private let shell: RankingCardShell
    private var rowViews: [RankingRowNSView] = []

    /// - Parameters:
    ///   - valueLabel: 表头右列指标名("CPU 时间" / "能耗" / "读写" / "流量")。
    ///   - accent: 标题与 meter 强调色(所在模块页的指标令牌)。
    ///   - cadenceNote: 节拍注脚("5 秒一档" 等)。
    ///   - emptyMessage: 空态覆盖;nil = 默认"首档采样后出数"说法。
    init(
        title: String,
        valueLabel: String,
        accent: Color,
        cadenceNote: String,
        emptyMessage: RankingEmptyMessage? = nil,
        rows: @escaping @MainActor () -> [ModuleRankingRow]
    ) {
        rowsProvider = rows
        self.accent = accent
        self.emptyMessage = emptyMessage ?? Self.defaultEmpty
        shell = RankingCardShell(title: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        shell.setTitle(title, accent: accent.ns)
        shell.setValueLabel(valueLabel)
        shell.setFootnote(cadenceNote)
        addSubview(shell)
        shell.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let rows = rowsProvider()
        // 基线轮(首见不出数)、门控清账、全零空闲都落空态,不报警不催促。
        shell.setEmpty(rows.isEmpty, message: emptyMessage)
        syncRowCount(rows.count)
        let tint = accent.ns
        for (view, row) in zip(rowViews, rows) {
            view.setContent(
                name: row.name,
                subtitle: row.subtitle,
                // "其他进程"桶(无类别)用通用符号瓦片,不冒充任何组类别。
                icon: .make(
                    bundlePath: row.bundlePath,
                    tileSymbol: row.fallbackCategory?.cardStyle.symbolName ?? "app.dashed",
                    tileColor: row.fallbackCategory?.cardStyle.tileColor ?? Surface.inkTertiary
                ),
                meterFraction: row.meterFraction,
                tint: tint,
                valueText: row.primaryText,
                alertsHighLoad: false
            )
            view.setAccessibilityLabel("\(row.name),\(row.subtitle),\(row.primaryText)")
        }
    }

    private func syncRowCount(_ count: Int) {
        while rowViews.count < count {
            let view = RankingRowNSView()
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.staticText)
            rowViews.append(view)
            shell.rowsStack.addArrangedSubview(view)
            view.fillWidth(of: shell.rowsStack)
        }
        while rowViews.count > count {
            rowViews.removeLast().removeFromSuperview()
        }
    }
}
