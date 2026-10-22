// 探针④(2026-10-22,P2 kickoff):IOReport "Energy Model" 通道组在本机(macOS 26 /
// MacBook Pro M4 / Mac16,1)的可用性、通道名与单位标签——研究档案 §5.1 的验证。
// 结论(输出见 04-ioreport-energy-model.output.txt):
//   1. 通道组活着:175 个通道,驱动 AppleT8132PMGR(M4 电源管理器);
//   2. ANE / GPU / CPU Energy / DRAM / DCS / SOC_* 四族功率通道全齐;
//   3. 单位逐通道不同(GPU Energy=nJ,其余=mJ)——"必须按 unit label 换算"
//      (docs/research/sensor-impl-comparison.md:92)实锤;
//   4. ★ API 形状已变:`IOReportCopyChannelsInGroup` 返回**响应字典**
//      {QueryOpts, IOReportChannels},不再是 stats 时代的裸 CFArray——
//      先取 IOReportChannels 才能逐通道;官方 getter(GetChannelName/
//      GetUnitLabel)接受通道字典仍工作。stats 旧解包路径在 macOS 26 会崩。
// 编译运行:swiftc -O 04-ioreport-energy-model.swift -o /tmp/p4 -lIOReport && /tmp/p4
// (IOReport 无公开头,手工 @_silgen_name 声明 + 链 /usr/lib/libIOReport.dylib。)

import Foundation

@_silgen_name("IOReportCopyChannelsInGroup")
func IORCopyChannels(
    _ group: CFString,
    _ filter: CFString?,
    _ flags: UInt64,
    _ tag: UInt64,
    _ dest: UnsafeMutableRawPointer?
) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOReportChannelGetChannelName")
func IORChanName(_ ch: UnsafeRawPointer?) -> CFString?
@_silgen_name("IOReportChannelGetUnitLabel")
func IORUnit(_ ch: UnsafeRawPointer?) -> CFString?

guard let obj = IORCopyChannels("Energy Model" as CFString, nil, 0, 0, nil)?.takeRetainedValue() as? NSDictionary,
      let chans = obj["IOReportChannels"] as? [NSDictionary] else {
    print("Energy Model 通道组不可读")
    exit(1)
}

print("响应字典 keys:", obj.allKeys.map { "\($0)" }.sorted(), "(macOS 26 形状,非裸数组)")
print("channels:", chans.count)
var names = Set<String>()
for c in chans {
    let p = Unmanaged.passUnretained(c as AnyObject).toOpaque()
    let n = IORChanName(p).map { $0 as String } ?? "?"
    let u = IORUnit(p).map { $0 as String } ?? "?"
    names.insert("\(n)  unit=\(u)")
}

for n in names.sorted() {
    print(n)
}
