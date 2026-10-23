# 07: 容器页——docker.sock 单发快照

**What to build:** 容器家族打穿:Live 适配器经 unix domain socket 打 docker HTTP API(本机 = OrbStack,标准 sock 路径,01 票已验证单发 stats),核心包纯值模型解析容器列表与每容器 stats 快照(CPU%/内存);主窗口新开容器 tab(容器表:名称/状态/CPU/内存),弹窗容器紧凑组(运行中列表)。节奏 = 页可见 30s 单发(socket 请求按容器数一次一发,不常开流;**stats 单发约 1s/容器,须并行单发**——探针⑦实测,7 容器串行 7s 不可接受);socket 缺席(OrbStack 未跑)安静空态,不重试风暴。JSON 解析对字段缺席容错。

**Blocked by:** 01(docker HTTP 验证)

**Status:** done

- [x] JSON 解析合成单测(字段缺席/容器列表空/stats 数值边界;含探针⑦四坑:
      字节级去块/CRLF 字形簇/零差分守卫)——7 例核心单测
- [x] OrbStack 退出后容器 tab 安静空态(engineReachable false 成功交付非失败;
      重试 = 30s 后下一发,无重试风暴)
- [x] check.sh 全绿(731 例:核心 391 + app 340);关两窗指纹全零
- [ ] OrbStack 运行时容器 tab 列出真实容器与资源读数,与 `docker ps`/OrbStack 界面互证 —— **待用户目验**
- [ ] 弹窗容器紧凑组出现 —— **待用户目验**

## Comments

**执行记录(2026-10-22 晚)**:
- 核心包 `ContainerModel`:UnixHTTPResponse(字节级 HTTP 解析 + chunked 去块,
  探针坑③④进单测——多字节 UTF-8 跨块不坏、状态行按字节 LF 切)+ 列表/Stats
  JSON 容错折算(CPU% = 单发 precpu 差分口径,Δsystem ≤ 0 → 0%;可超 100 =
  多核满载,docker stats 同口径)。7 例单测。
- Live `ContainerSensor`:socket 候选 /var/run/docker.sock → ~/.orbstack/run/
  docker.sock;请求模板钉死探针坑①②(Host: localhost + Connection: close);
  5s 接收超时 + 8MiB 上限防御;**stats 并行单发**(探针实测 ~1s/容器,串行
  7 容器不可接受);非运行容器跳过 stats。ContainerSensorProvider 30s 档,
  不可见零请求。
- ContainersCardView(名称/状态点/CPU%/内存;引擎缺席文案 "Docker / OrbStack
  未运行" 与空列表文案 "无容器" 分开);InertContainerSource 预览源。
- 容器 tab = 第 11 轴(网络后电池前,服务负载与 disk/network 相邻);Metric
  补 containers 令牌(§1.1 Projects 橙红行,零发明色);MonitorVisibility 加
  containersPage 旗。

**待用户目验**:
- OrbStack 运行时容器 tab 与 OrbStack 界面/`docker ps` 互证(数量/状态/CPU)。
- OrbStack 退出后空态文案安静出现,无报错弹窗。
- 弹窗(容器 tab 紧凑档)同形状(前 6 台)。

## Comments(2026-10-23 补记:静默失联实锤)

本票的 registry 登记**当时静默失败**(python 替换单行 pattern 对多行数组、无锚点断言):
`containers` 具名字段在场但从未进 registry 派发表——正式 app 里容器模块的传感器登记/
可见性门控/start 派发全部不达,容器页自 07 合入起一直空占位。测试未红的原因:smoke
直调 LiveContainerSource,绕过注册表;指纹零也不背书(视图不在树既因门控也因功能死了)。
2026-10-23 审计尾票的防漂移测试(MonitorAssemblyTests:Mirror 字段数 == registry 条数)
当场揭出并补登;该测试现为登记面的常驻门禁。教训三连:批量替换必须 assert 锚点;
新 feature 必须过 registry 派发路径的真实验证(不只直调源);防漂移测试早一天就一天止血。
