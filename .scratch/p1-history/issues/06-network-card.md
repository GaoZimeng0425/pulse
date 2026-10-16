# 06: 网络卡完整(速率/防御/累计)

**What to build:** 网络页进入弹窗与主窗口 tab 体系:实时上/下行速率(NET_RT_IFLIST2 差分,心跳型——进 Sampler 循环节奏,每轮一次 sysctl);Today/7 天累计(对 system 表 SQL 聚合,当地零点为日界);速率统计自动锁定主物理网卡——VPN(corporlink)/OrbStack 虚拟接口自动降级,不做 stats 的"除二"hack。断线重连、接口切换不出假尖峰。

**Blocked by:** 01、02、03(累计读 system 表)

**Status:** ready-for-agent

- [ ] 差分三件套单测:首读置零/负值钳零/重连跳变丢弃(合成计数序列)
- [ ] 接口选择与降级单测:注入假链路状态(SCDynamicStore 主接口 → 虚拟前缀降级 → getifaddrs 回退)
- [ ] 真机开 corplink 验证速率 sane(不翻倍不归零)
- [ ] Today/7 天累计与库内增量吻合;跨当地零点翻日
- [ ] 速率与 Stats.app 同刻对照一致(验收锚点②后半)
- [ ] 唤醒后第一轮作废(与 03 的唤醒清理协同);读缺失占位
