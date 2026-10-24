import Foundation

/// 重入探针(p2-review/01 ①):包住假源的 read(),停留 20ms 并记录同时在体内的
/// 调用数峰值——provider 若在锁外读源,两档并发 tick 时峰值 > 1。计数自带锁
/// (与被测 provider 的锁无关);`body` 收到的序号在锁内分配,单调递增。
final class ReentryProbe: @unchecked Sendable {
    private let counterLock = NSLock()
    private var inFlight = 0
    private var calls = 0
    private var peak = 0

    var peakInFlight: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return peak
    }

    func measure<T>(_ body: (_ ordinal: Int) -> T) -> T {
        let ordinal = enter()
        Thread.sleep(forTimeInterval: 0.02)
        defer { exit() }
        return body(ordinal)
    }

    private func enter() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        inFlight += 1
        calls += 1
        peak = max(peak, inFlight)
        return calls
    }

    private func exit() {
        counterLock.lock()
        defer { counterLock.unlock() }
        inFlight -= 1
    }
}
