import Foundation

/// 诊断报告(工单 11):报 bug 时一键复制的纯文本快照——应用/系统/采样统计/
/// 最近日志尾部,粘贴即用,用户不再手拼信息。
///
/// 拼装是**纯函数**:时钟(`now`)、统计数据源(`SamplingStats`)、日志尾
/// 全部注入,单测见 DiagnosticReportTests;日志读取只碰目录,同样注入
/// FileManager。取不到的字段如实标"暂无",不伪造 0。
public enum DiagnosticReport {
    /// 日志尾部截取行数上限:够定位近期行为,又不至于巨型粘贴。
    public static let logTailLineLimit = 50

    /// 生成时间戳的固定格式(本地时区;固定 locale,小数点/日期写法不随系统区域漂移)。
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// 拼装完整报告(纯文本,可直接粘贴)。
    public static func assemble(
        version: String,
        build: String,
        macOSVersion: String,
        chipName: String?,
        stats: SamplingStats,
        logTail: String?,
        now: Date
    ) -> String {
        var lines: [String] = []
        lines.append("Pulse 诊断报告")
        lines.append("生成时间: \(timestampFormatter.string(from: now))")
        lines.append("")
        lines.append("[应用]")
        lines.append("版本: \(version) (\(build))")
        lines.append("")
        lines.append("[系统]")
        lines.append("macOS: \(macOSVersion)")
        lines.append("机型芯片: \(chipName ?? unavailable)")
        lines.append("")
        lines.append("[采样统计]")
        if let startedAt = stats.startedAt {
            lines.append("运行时长: \(PulseFormat.duration(seconds: now.timeIntervalSince(startedAt)))")
        } else {
            lines.append("运行时长: \(unavailable)")
        }
        lines.append("采样轮数: \(stats.sampleCount > 0 ? "\(stats.sampleCount)" : unavailable)")
        lines.append("平均轮耗时: \(stats.averageRoundDuration.map { PulseFormat.milliseconds($0) } ?? unavailable)")
        lines.append("进程数峰值: \(stats.peakProcessCount.map(String.init) ?? unavailable)")
        lines.append("")
        lines.append("[最近日志(尾部 \(logTailLineLimit) 行,本地时间戳)]")
        lines.append(logTail ?? unavailable)
        return lines.joined(separator: "\n")
    }

    private static let unavailable = "暂无"

    /// 读取日志目录的最近 N 行(工单验收:本地时间戳、限制行数避免巨型粘贴)。
    /// CocoaLumberjack 文件不回写旧内容,按修改日期降序即"新 → 旧";从最新
    /// 文件起凑行,不够再翻次新,最后按时间序(旧 → 新)拼回。目录缺失/无
    /// 日志/行数为 0 → nil(报告侧标"暂无")。
    public static func logTail(
        directory: String,
        maxLines: Int = logTailLineLimit,
        fileManager: FileManager = .default
    ) -> String? {
        guard maxLines > 0 else { return nil }

        let entries = (try? fileManager.contentsOfDirectory(atPath: directory))?
            .compactMap { name -> (date: Date, name: String)? in
                guard name.hasSuffix(".log") else { return nil }
                let path = directory + "/" + name
                let attributes = try? fileManager.attributesOfItem(atPath: path)
                let date = attributes?[.modificationDate] as? Date
                return (date ?? .distantPast, name)
            }
            .sorted { lhs, rhs in
                lhs.date != rhs.date ? lhs.date > rhs.date : lhs.name > rhs.name
            }
        guard let entries, !entries.isEmpty else { return nil }

        var collected: [String] = []
        for entry in entries {
            guard let text = try? String(contentsOfFile: directory + "/" + entry.name, encoding: .utf8) else {
                continue
            }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // 文件以换行结尾时 split 留下尾部空串,丢掉这一行尾哨兵。
            if lines.last == "" { lines.removeLast() }
            collected = lines + collected
            if collected.count >= maxLines { break }
        }
        let tail = collected.suffix(maxLines)
        return tail.isEmpty ? nil : tail.joined(separator: "\n")
    }
}
