# 05 传感器派生卡 + 蓝牙设备卡 + 声音卡

Status: ready-for-agent
Blocked by: 01

## 做什么
传感器页只放 `SmcDerivedCardView` 紧凑档(拍板例外);外设页 = 蓝牙设备卡(开启 / 授权按钮、
状态点、电量条、RSSI 列)+ 声音卡。文案规则见 DESIGN.md「传感器卡文案与风扇条」。

## 参照
SmcCardViews.swift、BluetoothCardViews.swift、SoundCardViews.swift。
