# 03: 蓝牙开关态字段的去留——poweredOn 需拍板

**What to build:** 2026-10-23 审计残留(01 票记档):`BluetoothReading.poweredOn` 恒 nil(merge 硬编码死位)。两条路二选一,属产品/设计拍板,不属 bug 修:**A. 删字段**——蓝牙关时 pairedDevices() 返回 nil 已走"蓝牙不可用"空态文案,字段冗余,删掉是 API 简化;**B. 接线**——造异步电源态采集路(CoreBluetooth central state 回调缓存,IOBluetooth 无廉价同步查询),空态文案可区分"蓝牙关/无设备"。倾向 A(空态文案已够用,B 的常驻成本与收益不成比例),但**等用户拍板再动**。

**Blocked by:** 用户拍板(A 还是 B)

**Status:** needs-triage

- [ ] 用户拍板 A/B 记录在案
- [ ] A:字段删除 + 空态文案核对;B:异步电源态路径 + 文案区分 + 常驻成本记档
- [ ] check.sh 全绿
