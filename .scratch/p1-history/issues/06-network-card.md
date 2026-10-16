# 06: 网络卡完整(速率/防御/累计)

**What to build:** 网络页进入弹窗与主窗口 tab 体系:实时上/下行速率(NET_RT_IFLIST2 差分,心跳型——进 Sampler 循环节奏,每轮一次 sysctl);Today/7 天累计(对 system 表 SQL 聚合,当地零点为日界);速率统计自动锁定主物理网卡——VPN(corporlink)/OrbStack 虚拟接口自动降级,不做 stats 的"除二"hack。断线重连、接口切换不出假尖峰。

**Blocked by:** 01、02、03(累计读 system 表)

**Status:** done

- [x] 差分三件套单测:首读置零/负值钳零/重连跳变丢弃(合成计数序列)——NetworkSensorTests 8 例(首读/正常差分/回退钳零/换口作废/跳变边界/未知线速兜底/零线速按未知/elapsed 非正)
- [x] 接口选择与降级单测:注入假链路状态(SCDynamicStore 主接口 → 虚拟前缀降级 → getifaddrs 回退)——6 例(物理直用/utun 主接口降级/主接口缺席回退/旗标族过滤/前缀表/全员不合格占位)+ 入向死表回退 5 例(见实现记录)
- [x] 真机开 corplink 验证速率 sane(不翻倍不归零)——开:回退选中 utun4,下载期下行 ~2.5 MB/s 与 corplink-cli 自报 1 MB/s 同向同量级(隧道口计含封装开销),不翻倍不归零;关:回落 en0。**附带发现:本机 en0 入向计数死表**(见实现记录,已加死表回退)
- [x] Today/7 天累计与库内增量吻合;跨当地零点翻日——HistoryEngineTests 4 例:分钟行携带增量/跨零点翻日两段相加不重复计数(天真对两表同窗求和会 300/30 而非 150/15 的负例钉死)/无流量读零/库缺席 nil
- [x] 速率与 Stats.app 同刻对照一致(验收锚点②后半)——与 Stats 同源内核计数逐口对照(netstat -ib 同源):utun4 双向健全且随真实流量走,en0 入向恒 0(Obytes 折叠入向)——同一份计数,谁读都一样;屏幕侧 Stats 面板数值随工单 12 走查(锚点②一并覆盖)
- [x] 唤醒后第一轮作废(与 03 的唤醒清理协同);读缺失占位——SamplerWakeTests 唤醒轮作废 1 例 + 读缺失交付 nil 且基线保留 1 例;UI 占位沿 nil 语义

## 实现记录(2026-10-16)

- **传感器(Pulse/NetworkSensor.swift,算法移植 stats(MIT) 已注明)**:单接口字节计数 = sysctl NET_RT_IFLIST2 两段式,回包逐 if_msghdr 按 msglen 步进只认 RTM_IFINFO2(合成字节负例:截断/零长/index 不匹配);差分三件套 = 首读置零 → 换口作废 → 计数回退钳零 → elapsed 有限 → 跳变超"线速×1.5×窗口"丢弃(线速未知**或为 0** 按 100 Gbps 兜底——隧道口 ifi_baudrate 恒 0,按"已知 0 速"算上限会把每轮打死,真机实测出的修正)。不做 stats 的 VPN"带宽除二" hack:锁定单接口计数即真值。
- **接口选择与死表回退**:SCDynamicStore 主接口非虚拟直用,虚拟(utun/ipsec/ppp/tun/tap/gif/stf/wg + OrbStack 的 vmenet/bridge)降级 getifaddrs UP+RUNNING 非 loopback 非 p2p 物理口;**入向死表回退(本机实证新增)**——物理口 ifi_ipackets 恒 0 而 opackets 在走(驱动冻结入向计数,netstat -ib 同证,corplink 开关两态一致)时,改读"入向在场的活口"(UP+RUNNING 非死表口,取累计入向字节最多者,闲置 utun 的历史零星包抢不走主隧道);无活口保持物理口(down=0 是内核真相,不伪造)。单一接口计数,无翻倍路径。
- **真机对照(2026-10-16 探针 docs/probes/06-network-rate.swift,走 app 同一代码路径)**:开 corplink:选中 utun4,下载期下行 2.5 MB/s(增量 12.4MB/5s)与 corplink-cli 自报 1 MB/s 同向同量级(差值为隧道封装开销),峰值后回落不悬停;关 corplink:utun4 从链路表消失自动回落 en0,en0 下行 0 上行随流量(本机驱动把入向流量折叠计入 Obytes)。en0 入向计数死表属机器/驱动层事实,Stats/活动监视器同源同盲。
- **心跳集成**:网络是心跳型(spec),住 Sampler 循环——每轮一次 sample() 差分,SamplingUpdate.network 带速率+记账增量;读缺失(nil)交付 nil 且保留旧基线,丢弃轮速率为 0 增量为 0;invalidateDeltas 一并作废网络基线(唤醒首轮作废与 03 同轨,SystemMonitor 落地 NetworkRatesReading + 徽标契约 NetworkRateReading 转换 + 走势环(60 点纯逻辑环)。
- **历史管线**:system_min 的 net_rx/net_tx(03 建表恒空的列)自本轮起写入——MinuteRollupBuffer 逐轮求和跨窗清零,小时卷积 SQL 已有 SUM 两列原样生效;Today/7 天累计 = networkTotals(now:) SQL 聚合,**两段相加**防重复计数(已卷积分钟在分钟表与小时表各一份:当前小时边界前走 system_hour、边界后走 system_min),日界 = 注入 Calendar 的当地零点,7 天 = 今天 + 前 6 个当地日;库缺席返回 nil 占位。SystemMonitor 每轮落库后读回累计。
- **UI**:Metric.network 入令牌表(tab + accent .network 绿,展示序 磁盘→网络→电池),弹窗紧凑页 = 主卡(下行大数字 + 上行/Today/7 天/接口四列 + 合计走势)+ 流量累计明细卡(Today/7 天分方向四行),主窗口同构非紧凑;网络页不排组(磁盘同口径)。MetricTabModelTests 断言随六 tab 更新。
- **徽标契约(09)**:SystemMonitor.networkRate: NetworkRateReading? 落地填充——心跳轮结果在落地处转换(徽标只消费上/下行字节速率),读缺失轮保留上次好值,菜单栏网络槽位自此有真数。
- **单测纪律**:全合成计数序列/字节流/假链路状态 + 注入读数缝,零真实网络依赖(Live 源只做构造冒烟);新增 NetworkSensorTests 25(新文件)+ SamplerWakeTests 2 + HistoryEngineTests 4 + HistoryRollupTests 1,全量 413 例绿。
