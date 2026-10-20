# 后台服务判定以 plist 扫描的 launchd 服务清单补强,不读 launchctl

归组引擎的后台服务判定原本只有一条静态的惯例驻地前缀名单(launchd 域),自装在 /usr/local、/Library/<厂商>、/opt 的第三方 LaunchDaemon(corplink-service、Bitdefender 五守护、fleetdm orbit、brew 的 ollama)全部落孤儿进程,VPN 隧道的流量因此常年顶着"孤儿进程"行(launchd-attribution/01)。决定:引入 **launchd 服务清单**——扫描 launchd 各标准 plist 目录,取每个服务的 `Program`(缺省 `ProgramArguments[0]`,launchd 自身语义即 Program 优先)得到服务程序路径集合;兜底判定改为"挂在 launchd 之下 ∧(位于 launchd 域 ∨ 命中清单)"。静态域不动(/usr/local、/opt/homebrew 仍刻意不算域,评审 S3),清单只给"确实有 plist 声明"的程序一条判定路径。

**不读 launchctl 的理由(2026-10-20 真机探针)**:`launchctl print system` 近零成本,但 services 表只有 pid / 状态 / label,**不给程序路径**;要拿路径得逐 label 再调 `launchctl print system/<label>`(本机 447 次子进程)或解析 `launchctl dumpstate`(8MB、29 万行、110ms),且作为子进程还要配 nettop 同级的超时与看门狗。plist 扫描纯文件读、零子进程、可变层几毫秒;本机 354 个在跑的 launchd 服务里,静态域覆盖 310、.app 归属先收 26、清单救回 8。

**被否的替代:launchctl 的 pid 集合。** services 表直接给运行中服务的 pid,两次子进程就能得到"launchd 眼里哪些 pid 是它的服务",权威且便宜。否掉的原因:守护重启后新 pid 要等下一次刷新才进集合,一分钟内会在孤儿 / 后台服务之间抖动;按程序路径匹配则对重启天然稳定。

**两层缓存。** /System/Library/LaunchDaemons|LaunchAgents 共 911 个 plist(冷扫 339ms / 热 135ms)在密封系统卷上,不重启装系统更新就不可能变——进程生命周期内只扫一次,两目录都枚举成功才冻结,否则每次刷新重试。可变层五个目录——/Library/LaunchDaemons、/Library/LaunchAgents、/Library/Apple/System/Library/LaunchDaemons、/Library/Apple/System/Library/LaunchAgents、~/Library/LaunchAgents(本机 41 个文件)——每 60 秒重扫。清单读取不进采样热路径。

**匹配口径:字面路径 ∪ 扫描时 realpath 的全等匹配,realpath 只做在清单侧。** 引擎拿到的进程路径来自 proc_pidpath,是 vnode 真路径:Cryptexes 代理实测为 /System/Volumes/Preboot/Cryptexes/App/usr/libexec/AuthenticationServicesAgent,而 plist 字面是 /System/Cryptexes/App/…,两者只经 realpath 相等——不存 realpath 就匹配不上。采样热路径上绝不对进程路径做 realpath。

**已知局限(都如实接受,不加启发式)**:① 升级后未重启的符号链接守护——ollama 的 plist 写 /opt/homebrew/opt/ollama/bin/ollama,链接现指 Cellar 0.40.6,正在跑的老进程却是 0.40.2,字面与 realpath 都对不上,重启前仍落孤儿;不为任何包管理器的版本目录做版本无关匹配。② 解释器程序——密封层有 /bin/bash、/usr/bin/true 这类程序进清单,出生登记缺失且被重挂到 launchd 的脚本可能被读成后台服务;反向,plist 经 `sh -c` 包装的真守护不在清单里仍落孤儿;两向都不特判(S3 要保的 /usr/bin/ssh 不在任何 plist 里)。③ 清单是磁盘声明不是运行时状态:从非标准路径 bootstrap 的服务不可见,禁用的服务仍在清单里。④ 程序在 .app 容器内的守护(BDLDaemon 类)仍被 App 归属先收走,判定顺序不动(2026-10-20 triage 拍板)。读取失败保留上次好清单(ADR-0004 lastGood 惯例,偏离工单 brief 的"按空清单处理"字面);首轮尚无清单时为空集,即只剩静态域。
