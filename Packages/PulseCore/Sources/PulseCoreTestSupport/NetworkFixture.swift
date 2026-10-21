import Foundation
import PulseCore

/// 网络合成计数夹具:核心包 NetworkModelTests 与 app 侧 NetworkSensorTests 共用(p1-history/06)。
public enum NetworkFixture {
    public static func counters(
        _ interface: String = "en0",
        up: UInt64,
        down: UInt64,
        upPackets: UInt64 = 1000,
        downPackets: UInt64 = 1000,
        baud: UInt64? = 1_000_000_000,
        at: UInt64
    ) -> NetworkCounters {
        NetworkCounters(
            interface: interface,
            upBytes: up,
            downBytes: down,
            upPackets: upPackets,
            downPackets: downPackets,
            linkBaudrateBitsPerSecond: baud,
            atUptimeNanos: at
        )
    }
}
