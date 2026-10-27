import Foundation

// MARK: - 特权助手读侧(p3-root-mcp/03,文件通信版)

/// 读 helper 的快照文件(/var/run/com.gaozimeng.pulse.helper.json,root 域,
/// 用户态不可伪造——伪造面 = root = 已出信任边界,与 XPC 时代同口径记档)。
/// 文件缺席 = 未装/未跑(调用方按轮重试,失败翻转才记日志)。@unchecked
/// Sendable:无状态。
final class EnergyHelperClient: @unchecked Sendable {
    private let path = "/var/run/com.gaozimeng.pulse.helper.json"

    typealias Samples = [(pid: Int, name: String, impact: Double)]

    func fetchLatest() async throws -> (samples: Samples, collectedAt: Date) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw HelperClientError.snapshotMissing
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let epochMs = object["epochMs"] as? Double,
              let rawRows = object["rows"] as? [[String: Any]]
        else {
            throw HelperClientError.snapshotMalformed
        }
        // 值域防御(坏文件不进管线):能耗影响为正有限值。
        let rows: Samples = rawRows.compactMap { row in
            guard let pid = (row["pid"] as? NSNumber)?.intValue,
                  let name = row["name"] as? String,
                  let impact = (row["impact"] as? NSNumber)?.doubleValue,
                  impact.isFinite, impact >= 0
            else { return nil }
            return (pid, name, impact)
        }
        return (rows, Date(timeIntervalSince1970: epochMs / 1000))
    }
}

enum HelperClientError: Error {
    case snapshotMissing
    case snapshotMalformed
}
