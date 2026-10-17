import SwiftUI

// MARK: - 磁盘卡明细视图(工单 05):各卷对账明细 + 本地快照列表
// 内容模型(容器对账/快照识别)在 DiskSensor(纯逻辑,单测覆盖);本文件只做
// SwiftUI 外观,与 Memory by App 环形卡同层——tab 主卡之下的补充卡,走预览 +
// 手动验收(spec 测试决策)。

/// 各卷已用明细(工单 05 ③):Data 卷在首,其后其余同容器卷与"其他卷"差额;
/// 每行 = 标签 + 已用(十进制 GB)+ 占容器已用的比例条。合计行 = 容器已用,
/// 与大数字同一出处(对账不变式由单测钉死,UI 不重算)。
struct DiskVolumeBreakdownView: View {
    let capacity: DiskCapacityReading?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let capacity {
                row(
                    capacity.dataVolume.label,
                    usedBytes: capacity.dataVolume.usedBytes,
                    totalBytes: capacity.containerUsedBytes,
                    prominent: true
                )
                ForEach(capacity.otherVolumes) { volume in
                    row(volume.label, usedBytes: volume.usedBytes, totalBytes: capacity.containerUsedBytes)
                }
                if let unaccounted = capacity.unaccounted {
                    row(unaccounted.label, usedBytes: unaccounted.usedBytes, totalBytes: capacity.containerUsedBytes)
                }
            } else {
                Text("容量对账暂不可用")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: isCompact ? 12 : 18))
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "externaldrive")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Metric.disk.accentColor)
            Text("各卷明细")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let capacity {
                Text("合计 \(PulseFormat.diskCapacity(capacity.containerUsedBytes))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func row(_ label: String, usedBytes: UInt64, totalBytes: UInt64, prominent: Bool = false)
        -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11.5, weight: prominent ? .medium : .regular))
                    .foregroundStyle(prominent ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(PulseFormat.diskCapacity(usedBytes))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Surface.cardHigh)
                    let fraction = totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
                    Capsule()
                        .fill(Metric.disk.accentColor.opacity(prominent ? 0.9 : 0.55))
                        .frame(width: max(2, proxy.size.width * min(1, fraction)))
                }
            }
            .frame(height: 4)
        }
    }
}

/// 本地快照列表(工单 05 ④):Data 卷快照,最旧在前;TM 前缀识别来源。
/// 空 = 真的没有("暂无快照");unavailable = 读不到("不可用"占位,不伪造)。
struct DiskSnapshotsCardView: View {
    let listing: DiskSnapshotListing?
    var isCompact = false

    /// 明细行上限(其余折叠成一行计数,快照常有十几个不穷举)。
    private static let visibleLimit = 6

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Metric.disk.accentColor)
                Text("本地快照")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: isCompact ? 12 : 18))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch listing {
        case .listing(let snapshots) where !snapshots.isEmpty:
            ForEach(snapshots.prefix(Self.visibleLimit)) { snapshot in
                snapshotRow(snapshot)
            }
            if snapshots.count > Self.visibleLimit {
                Text("…共 \(snapshots.count) 个")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        case .listing:
            Text("暂无本地快照")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        case .unavailable, nil:
            // 快照读不到(rc<0/非 APFS 卷):占位,不伪造(petal/探针②口径)。
            Text("快照信息不可用")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func snapshotRow(_ snapshot: DiskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.kindTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(snapshot.isTimeMachine ? Metric.disk.accentColor : .secondary)
                Spacer(minLength: 8)
                Text(Self.dateFormatter.string(from: snapshot.createdAt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(snapshot.name)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - 预览(合成读数,外观与密度走预览 + 手动验收)

#Preview("磁盘明细卡") {
    let capacity = DiskCapacityReading(
        volumeName: "Macintosh HD",
        containerTotalBytes: 494_384_773_120,
        containerUsedBytes: 284_700_000_000,
        availableForImportantUsageBytes: 209_550_000_000,
        purgeableBytes: 6_610_000_000,
        dataVolume: DiskVolumeUsage(label: "数据卷", mountPoint: "/System/Volumes/Data", usedBytes: 250_000_000_000),
        otherVolumes: [
            DiskVolumeUsage(label: "macOS", mountPoint: "/", usedBytes: 15_000_000_000),
            DiskVolumeUsage(label: "虚拟内存", mountPoint: "/System/Volumes/VM", usedBytes: 8_000_000_000),
        ],
        unaccounted: DiskVolumeUsage(label: "其他卷", mountPoint: "(unaccounted)", usedBytes: 11_700_000_000),
        snapshots: .listing([
            DiskSnapshot(name: "com.apple.os.update-24F74", createdEpoch: 1_760_000_000),
            DiskSnapshot(
                name: "com.apple.TimeMachine.2026-10-15-030000.local",
                createdEpoch: 1_760_500_000
            ),
        ])
    )
    let rates = (0..<56).map { i in DiskRatePoint(read: Double(i % 9) * 3e6, write: Double(i % 5) * 2e6) }
    let throughput = DiskThroughputReading(
        current: DiskRates(readBytesPerSecond: 12e6, writeBytesPerSecond: 4e6),
        trend: rates
    )
    return ScrollView {
        VStack(spacing: 12) {
            MetricMainCardView(model: .disk(capacity: capacity, throughput: throughput))
            HStack(alignment: .top, spacing: 16) {
                DiskVolumeBreakdownView(capacity: capacity)
                DiskSnapshotsCardView(listing: capacity.snapshots)
            }
        }
        .padding(16)
    }
    .frame(width: 760)
    .background(Surface.window)
}
