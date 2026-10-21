import Darwin
import Foundation
import PulseCore

// MARK: - 采集源

/// Darwin 薄适配器:host_processor_info(PROCESSOR_CPU_LOAD_INFO)——每核
/// [user, system, idle, nice] 计数,与活动监视器 / top 的系统占用同源。
/// (注意 flavor 是 processor 侧的 PROCESSOR_CPU_LOAD_INFO;
/// HOST_CPU_LOAD_INFO 是 host_statistics 的 flavor,用在这里会得到参数错。)
/// 返回缓冲由 vm_allocate 分配,读完必须 vm_deallocate 归还。
struct LiveCoreTickSource: CoreTickSource {
    func sample() -> CoreTickSample {
        var coreCount: natural_t = 0
        var infoPointer: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &coreCount,
            &infoPointer,
            &infoCount
        )
        guard kr == KERN_SUCCESS, let info = infoPointer, coreCount > 0 else {
            return CoreTickSample(busyTicks: [], totalTicks: [], takenAt: Date())
        }
        defer {
            // host_processor_info 分配的内存不归 ARC 管,手工归还。
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let statesPerCore = Int(CPU_STATE_MAX)
        var busy: [UInt64] = []
        var total: [UInt64] = []
        var userTicks: [UInt64] = []
        var systemTicks: [UInt64] = []
        busy.reserveCapacity(Int(coreCount))
        total.reserveCapacity(Int(coreCount))
        userTicks.reserveCapacity(Int(coreCount))
        systemTicks.reserveCapacity(Int(coreCount))
        for core in 0 ..< Int(coreCount) {
            let base = core * statesPerCore
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            busy.append(user + system + nice)
            total.append(user + system + idle + nice)
            userTicks.append(user + nice)
            systemTicks.append(system)
        }
        return CoreTickSample(
            busyTicks: busy,
            totalTicks: total,
            takenAt: Date(),
            userTicks: userTicks,
            systemTicks: systemTicks
        )
    }
}
