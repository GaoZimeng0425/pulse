import PulseCore
import SwiftUI

// MARK: - 应用子页(p4-uninstaller/01):清单只读;展开残留与卸载动作是 02/03 票

//
// 行 = 图标 + 名字 + 路径副标 + brew 徽标 / 灰行态 chip + .app 实际占用(口径与
// 空间地图一致)。灰行(先退出 / 无权限)只陈述不提供退出按钮(spec);点行展开
// 残留清单交互在 02 票接入,本票不做占位假交互。
// 台账披露(如实上屏,不静默消失):Apple 系统应用与签名判不了的都计数千金展示。

struct AppListSection: View {
    let model: UninstallModel

    private var accent: Color {
        Metric.disk.accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.phase {
            case .idle, .collecting:
                loadingView(text: "正在收集应用清单…")
            case let .sizing(entries):
                loadingView(text: "正在统计占用 · 已扫描 \(entries) 项")
            case .finished:
                content
            }
        }
        // 进子页空态才自动扫(已有清单不重复烧);切走取消(无常驻采集,spec)。
        .task { model.loadIfNeeded() }
        .onDisappear { model.cancel() }
    }

    // MARK: 头部

    private var header: some View {
        CardHeader(symbolName: "square.grid.2x2", title: "应用", tint: accent) {
            HStack(spacing: 8) {
                if let output = model.output {
                    Text(summaryText(output))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help("重新收集(签名、brew 徽标、运行态都可能已变化)")
            }
        }
    }

    private func summaryText(_ output: AppCatalogOutput) -> String {
        var text = "共 \(output.entries.count) 个应用"
        if output.ledger.excludedAppleSigned > 0 {
            text += " · 已隐藏 \(output.ledger.excludedAppleSigned) 个 Apple 系统应用"
        }
        if output.ledger.excludedUnverifiableSignature > 0 {
            text += " · \(output.ledger.excludedUnverifiableSignature) 个签名无法验证未列出"
        }
        return text
    }

    // MARK: 清单

    private var content: some View {
        let entries = model.output?.entries ?? []
        return Group {
            if entries.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            AppRow(entry: entry, leader: entries.compactMap(\.sizeBytes).max() ?? 0)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 120, maxHeight: .infinity)
            }
        }
        .background(Surface.card, in: .rect(cornerRadius: 18))
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("未发现可卸载的应用")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func loadingView(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .background(Surface.card, in: .rect(cornerRadius: 18))
    }
}

// MARK: - 行

private struct AppRow: View {
    let entry: UninstallAppEntry
    /// 大小条的最大值(条形对照,与开发者垃圾行同款语言)。
    let leader: Int64

    private var isDimmed: Bool {
        entry.rowState != .normal
    }

    var body: some View {
        HStack(spacing: RankingListMetrics.spacing(compact: false)) {
            Image(nsImage: AppIconCache.icon(forBundle: entry.path, pointSize: 22))
                .resizable()
                .frame(width: 22, height: 22)
                .opacity(isDimmed ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: RankingListMetrics.valueFontSize(compact: false), weight: .medium))
                    .lineLimit(1)
                Text(entry.path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .opacity(isDimmed ? 0.55 : 1)
            Spacer(minLength: 8)
            if let cask = entry.brewCaskName {
                BrewChip(caskName: cask)
            }
            stateChip
            MeterBar(
                fraction: meterFraction,
                tint: .secondary
            )
            .frame(width: RankingListMetrics.meterWidth(compact: false))
            HStack(spacing: 4) {
                Text(sizeText)
                    .font(.system(size: RankingListMetrics.valueFontSize(compact: false), weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if entry.isPartial {
                    Text("部分")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: RankingListMetrics.valueWidth(compact: false), alignment: .trailing)
        }
        .padding(.horizontal, RankingListMetrics.rowInset)
        .padding(.vertical, 4)
        .opacity(isDimmed ? 0.75 : 1)
    }

    @ViewBuilder
    private var stateChip: some View {
        switch entry.rowState {
        case .normal:
            EmptyView()
        case .running:
            StateChip(text: "先退出")
        case .noPermission:
            StateChip(text: "无权限")
        }
    }

    private var sizeText: String {
        entry.sizeBytes.map { PulseFormat.memory(UInt64(max(0, $0))) } ?? "—"
    }

    private var meterFraction: Double {
        guard let bytes = entry.sizeBytes, leader > 0 else { return 0 }
        return MeterNormalization.fraction(Double(bytes), leader: Double(leader))
    }
}

/// 灰行态 chip:客观状态非警示(InUseChip 同款配方——灰、不喊)。
private struct StateChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Surface.inkTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Surface.inkTertiary.opacity(0.15), in: .capsule)
            .lineLimit(1)
    }
}

/// brew 徽标:来源事实(收据匹配),中性灰胶囊;名字进 tooltip 供查证。
private struct BrewChip: View {
    let caskName: String

    var body: some View {
        Text("brew")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Surface.inkTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Surface.inkTertiary.opacity(0.15), in: .capsule)
            .help("Homebrew Cask:\(caskName)(卸载将走 brew uninstall,03 票)")
    }
}
