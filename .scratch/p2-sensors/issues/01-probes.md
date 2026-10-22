# 01: 探针补全——SMC 真读数键表 / GATT 电池 / docker.sock HTTP(为 04/06/07 消雷)

**What to build:** 三个实施前探针,各一次性跑在本机并存档进探针目录(先例:探针 ①–④ 与 p1-history/01):① SMC 真读数——AppleSMC 用户态连接打穿(FNum 风扇数、若干温度键、sp78/fpe2 解码验证),顺带 dump 本机全键清单里 T/V/P/I 前缀键与风扇键,产出 04 的传感器命名表种子数据;② GATT 电池——CoreBluetooth 按需连接一台真设备读电池服务(0x180F/0x2A19),验证连接时长与权限面(应免弹窗);③ docker.sock——OrbStack 运行态下单发 HTTP(容器列表 + 单容器 stats stream=false),验证 API 版本协商与 JSON 形状。探针失败同样落档:如实记录失败模式,消费票据此走回退路径,不算探针票失败。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] SMC 探针跑通:风扇数与至少一个温度键真读数成功,全键清单落档(命名表种子)
- [x] GATT 电池探针有结论:读到真电量,或如实记录失败模式(超时/无该服务/权限)
- [x] docker.sock 探针有结论:单发 stats JSON 解析出 CPU/内存读数,或记录 OrbStack 缺席时的 socket 状态
- [x] 三个探针源码+输出按既有编号规则存档 docs/probes/,不留在 /tmp

## Comments

**2026-10-22 执行完毕(探针⑤⑥⑦,docs/probes/05-07 + .output.txt):**

- **SMC(⑤)**:AppleSMC 用户态连接**免权限弹窗实证**;#KEY=2806,枚举 9.2ms;T/V/P/I/F 前缀 402 键(04 命名表种子已落档);186 个温度键可读(注意:Ta## 系列恒 6.2°C 是冻死坏传感器,<10 丢弃防御实证必要);**FNum=1**(本机 Mac16,1 SMC 只报一台风扇——不是想当然的双风扇);电池顺手键 **PPBR=1.309W / PDTR≈47.96W(48W 适配器)**,04 票升级路径可行。
- **GATT(⑥)**:蓝牙 poweredOn;20s 扫到一台 "P08"(RSSI -64,广播不带服务),连接 12s 超时(设备不在此机可连态)——**如实落档**:GATT 路维持"按需建连、设备在场才可达"设计。同刻补源①证据:IORegistry HID 路读到妙控板 BatteryPercent=44,开箱即用。
- **docker(⑦)**:三发全通(_ping 200 / 列表 200(133ms,7 容器:openmaic/deeptutor/postgres/searxng 真实栈)/ stats 200)。**踩掉四个坑已写进探针头注释**:Host 头须合法主机名(代理对 "Host: docker" 断连)、Connection: close 必须显式(否则 recv 挂死)、docker 29.8.2 对 1.0 也回 chunked 且必须**字节级**去块(块边界是字节数,String 索引切坏多字节 UTF-8)、Swift CRLF 聚字形簇致 firstIndex(of:"\n") 恒 nil。**stats 单发约 1s/容器**(docker 采样窗口)——07 票须并行单发,7 容器 ≈1s 总延迟。
- OrbStack 系探针临时拉起、跑完已退出复原(探针前引擎是关的)。
