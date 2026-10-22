# 07: 容器页——docker.sock 单发快照

**What to build:** 容器家族打穿:Live 适配器经 unix domain socket 打 docker HTTP API(本机 = OrbStack,标准 sock 路径,01 票已验证单发 stats),核心包纯值模型解析容器列表与每容器 stats 快照(CPU%/内存);主窗口新开容器 tab(容器表:名称/状态/CPU/内存),弹窗容器紧凑组(运行中列表)。节奏 = 页可见 30s 单发(socket 请求按容器数一次一发,不常开流;**stats 单发约 1s/容器,须并行单发**——探针⑦实测,7 容器串行 7s 不可接受);socket 缺席(OrbStack 未跑)安静空态,不重试风暴。JSON 解析对字段缺席容错。

**Blocked by:** 01(docker HTTP 验证)

**Status:** ready-for-agent

- [ ] OrbStack 运行时容器 tab 列出真实容器与资源读数,与 `docker ps`/OrbStack 界面互证
- [ ] OrbStack 退出后容器 tab 安静空态,无报错无重试风暴(日志佐证)
- [ ] JSON 解析合成单测(字段缺席/容器列表空/stats 数值边界)
- [ ] 弹窗容器紧凑组出现
- [ ] 关两窗指纹全零;check.sh 全绿
