# Pulse — 菜单栏"App 视角"系统监视器技术方案

> 目标:做一个 Vitals (vitalsmac.com) 的个人版。核心诉求不是看数字,而是回答
> **"到底是什么在占用我的 CPU"** —— 比如 2026-10-12 那次:load 52,
> 真相是 octok-client 两个 worktree 同时跑质量门禁(cargo test + vitest --coverage)
> + WaifuX 常驻白烧 60% + OrbStack VM 86%。活动监视器只会给你 1000 行进程列表。
>
> **范围(2026-10-15 拍板)**:完整复刻 Vitals 的全部传感器面板——磁盘、网络、
> GPU、神经网络引擎、电池、声音、蓝牙、容器,不做功能阉割;在此之上保留两处
> 做深(项目/agent 归因、MCP)。早期"别做全功能克隆"的收缩范围决定作废,见 §11。

---

## 1. Vitals 拆解:它做了什么,哪些能复刻

| 功能 | 原理 | 复刻难度 |
|---|---|---|
| 1000 进程 → 60 个 App | 进程归属引擎(本方案 §3,核心) | ★★★ 这是产品壁垒 |
| 30 天历史 | 本地 SQLite + 降采样 | ★★ |
| CPU/内存/磁盘/网络 每.App 汇总 | libproc 公开 API | ★ |
| 系统卡:磁盘(容量/读写速率/Written Today) | APFS 容器级容量口径(§4,算法参考 petal §12)+ 每 pid rusage diskio 求和差分(采样器已在采) | ★ |
| 系统卡:网络(下载/上传/Today/7 天) | `sysctl NET_RT_IFLIST2` 每网卡字节计数差分;累计卷落 SQLite | ★ |
| 系统卡:电池(电量/剩余/功耗/健康) | IOPowerSources + IORegistry `AppleSmartBattery`(健康/循环/电流×电压=功率) | ★★ |
| 系统卡:GPU / 神经网络引擎 | GPU 利用率 = IORegistry `PerformanceStatistics`(免 root);ANE = IOReport "Energy Model" 用户态差分——均经 stats 4.2 万用户验证(§12) | ★★ |
| GPU / 能耗 每.App | IOReport task 通道,需 root,半私有 → P3 配 helper | ★★★ |
| 温度/风扇 | SMC user client(社区文档完备) | ★★ |
| 声音 tab(输出音量/输入电平/每 App 音量) | CoreAudio 设备属性;macOS 14+ 进程音频 API | ★★ |
| 蓝牙 tab(外设电量) | IOBluetooth 已连设备 service 数据,需蓝牙权限 | ★★ |
| 容器 tab(Docker/OrbStack) | docker.sock HTTP API 或 `docker ps` 子进程 | ★ |
| 发现被遗忘的 dev server | argv 模式匹配 + 监听端口枚举 | ★★ |
| 异常告警 | 阈值 + 迟滞的规则引擎 | ★ |
| 菜单栏常驻,合盖采样 0.1% 单核 | 5s 慢采样 / 打开时 1s | ★ |
| 可选 root helper 读系统进程 | SMAppService daemon + XPC | ★★ P3 |
| MCP server 供 AI 询问 | 顺手做,对 AI coding 用户价值极大 | ★ P3 |

无 App Store 沙盒问题:自用 sideload,本地构建签名即可。

## 2. 总体架构

```
┌─ 菜单栏 App (Tauri 2 / SwiftUI) ──────────────────────────┐
│                                                            │
│  Sampler (5s 合盖 / 1s 开窗)                                │
│   └─ proc_listallpids + 每 pid 3 次 proc_pidinfo            │
│        ↓ 原始进程快照                                       │
│  LineageCache  ← 每 2s 记录新进程出生时的父链(防孤儿断链)     │
│        ↓                                                   │
│  GroupingEngine  ★核心★  (App 归属 → 项目归属 → 分类兜底)     │
│        ↓ 分组快照 (group_id → cpu/mem/disk/net/procs)       │
│  ├─ RingBuffer 内存 5s 原始值,保留 1h                        │
│  ├─ SQLite: 1min rollup(7d)+ 1h rollup(30d)               │
│  ├─ AlertEngine (规则+迟滞 → UNUserNotificationCenter)       │
│  ├─ DevServerFinder (argv 模式 + LISTEN 端口)               │
│  ├─ Popover UI (Top-N App 卡片 / 项目卡片 / 下钻进程树)       │
│  └─ MCP server (P3): why_cpu() / top_groups()               │
└────────────────────────────────────────────────────────────┘
```

成本预算:~800 个 pid,每 pid 3 次 proc_pidinfo(微秒级),一轮 < 5ms,
每 5s 一次 ≈ 0.1% 单核,与 Vitals 宣称一致。

## 3. ★归组引擎★ —— 回答"到底是什么在占用"的三层归因

这是整个方案的灵魂。三层,逐级 fallback:

### 3.1 第一层:App 归属(bundle)

- `proc_pidpath(pid)` 拿可执行路径;路径含 `.app/Contents/MacOS/` → 归属该 bundle
  (读 `Contents/Info.plist` 的 `CFBundleName` / `CFBundleIdentifier` 做显示名)。
- 子进程(Helper/Renderer/XPC)自动跟随父进程的归属。

### 3.2 第二层:父链上溯 + 出生登记(解决孤儿问题)

- 对非 bundle 进程,沿 `kinfo_proc.kp_ppid` 向上走,直到遇到 bundle App 或 launchd(1)。
  `rustc ← cargo ← zsh ← node(agent CLI) ← zcode.app` 这条链就是这么做出来的。
- **关键坑**:中间进程先死,子进程会被 reparent 到 launchd(ppid=1),链断。
  解法:**采样器每 2s 扫描新 pid,在出生时把父链快照存进 LineageCache**
  (SQLite 表 `lineage(pid, parent_chain, first_seen, argv, cwd)`)。
  agent 类 CLI 会话进程是长命的,绝大多数链在出生时就能抓全。
- 查询时:先看活链,活链断了查 LineageCache 的历史记录。

### 3.3 第三层:项目归因(dev 进程的杀手锏,Vitals 也没做深的部分)

rustc/node/vitest 这些可执行文件是通用的,"哪个 App"没有意义,**哪个项目才有意义**:

1. `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO)` 拿 **cwd**;
2. 扫 **argv**(cmdline)里的路径;
3. 与用户配置的项目根列表匹配(如 `~/Documents/Antalpha/*`、worktree 目录
   `.worktrees/<name>`),命中 → 归组为 `项目名 @ worktree/分支`。

今早场景的最终呈现:

```
🔥 octok-client @ skill-manage-read-and-index   445% CPU   ▲ 质量门禁
   ├─ cargo test --workspace     1 进程   13 × rustc 合计 ~320%
   ├─ vitest --coverage          2 进程   122%
   └─ 由 node (zcode agent 会话) 拉起, 14:40 开始, 已 25 分钟
🔥 OrbStack (VM)                                 86%   7 容器, deeptutor unhealthy
🔥 WaifuX                                        55%   已常驻 3 天
```

点开任一行 → 进程树、启动时间、cwd、完整 argv、动作(结束整组 / kill 进程树 / 复制诊断报告——Vitals 1.3.5 的那个功能)。

### 3.4 兜底分类

匹配不上任何层的:按 launchd domain 归"后台服务"(LaunchAgents/LaunchDaemons
路径推断)、WindowServer/内核任务归"系统"、其余归"孤儿进程"(橙色高亮——
孤儿往往正是问题所在,值得单独一类)。

## 4. 数据采集:API 清单(全部语言无关)

| 指标 | API | 权限 | 备注 |
|---|---|---|---|
| 进程列表 | `proc_listallpids()` | 无 | libproc.h |
| 父 pid / 状态 | `sysctl KERN_PROC` 或 `PROC_PIDT_SHORTBSDINFO` | 无 | |
| 可执行路径 | `proc_pidpath()` | 自有进程全量;他人进程部分受限 | |
| **CPU 时间** | `PROC_PIDTASKINFO` → `pti_total_user+system`(ns),差分/墙钟 = CPU% | 无 | 与活动监视器同算法 |
| **cwd / text 路径** | `PROC_PIDVNODEPATHINFO` | 自有进程 | 项目归因的原料 |
| **磁盘读写** | `proc_pid_rusage()` → rusage_info_v3 的 `ri_diskio_bytesread/written` | 无 | 公开 |
| 内存 | `PROC_PIDTASKINFO` → `pti_resident_size`;物理足迹用 rusage `ri_phys_footprint` | 无 | |
| 磁盘容量(容器级) | `statfs('/')` 推容器号 → `getmntinfo` 枚举同容器 APFS 卷 → 逐卷 `getattrlist(ATTR_VOL_SPACEUSED)` → 与容器总量对账 | 无 | 裸 `statfs` 的 free 在 APFS 上不可信(容器共享空闲 + 快照污染);算法照 petal `src/disk.rs: startup_layout()` 翻译(MIT 可抄);各卷之和 < 容器总量时差额记"Other volumes"兜底,必做否则对不上(disk.rs:241-245);30-60s 或卷事件触发,不进采样轮 |
| 可清除空间(purgeable) | CFURL `kCFURLVolumeAvailableCapacityKey` 与 `...ForImportantUsageKey` 两 key 差值 | 无 | "实际可用"的 Finder 口径;本地快照/iCloud 可回源/可清缓存都算在这 |
| APFS 快照列表 | `fs_snapshot_list`(公开 libc,免 root) | 无 | 按名字认出 Time Machine 本地快照——"删了文件磁盘还满"的头号元凶,告警卡素材 |
| 磁盘 SMART 健康 | `diskutil info` 解析 "SMART Status:" 行 | 无 | 可选小字段;几乎不变,低频缓存调用(开机/每小时一次),不进采样轮;要更细再上 IOKit NVMe SMART |
| 磁盘吞吐(系统) | 每 pid `ri_diskio_bytesread/written` 求和差分(采样器已在采) | 无 | 内核自身 IO 不计入,误差可接受;要精确 IOPS 再上 IOKit DKIO |
| 网络吞吐(系统) | `sysctl NET_RT_IFLIST2` → `if_data64.ifi_ibytes/obytes` 按网卡差分 | 无 | 差分三件套必做:首读置零 / 负值钳零 / 重连跳变丢弃(stats Net/readers.swift:304-323);主接口选 `SCDynamicStore` 全局 IPv4,utun/ipsec 等虚拟前缀降级找物理口(:111-165)——VPN/OrbStack 机器上是刚需;Today/7 天落 SQLite 累计 |
| 网络/每进程 | 无公开 API。`nettop -P -L`(JSON 流)子进程解析 | 无 | P1 先做系统总量;每 App 归因 P3(配 helper 更稳) |
| 电池 | `IOPSCopyPowerSourcesInfo`(电量/充放/剩余时间)+ IORegistry `AppleSmartBattery`(健康/循环次数/InstantAmperage×Voltage=功率) | 无 | 全部用户态可读;建议事件驱动(`IOPSNotificationCreateRunLoopSource`)而非轮询;`NotChargingReason != 0` 要显示"优化充电已介入"而非故障(stats Battery/readers.swift:148-158);健康键回退链 + 设计容量为 0 钳 1 防除零 |
| GPU 利用率(系统级) | IORegistry `kIOAcceleratorClassName` → `PerformanceStatistics` 字典("Device Utilization %"/"Renderer Utilization %"/"Tiler Utilization %"/温度/频率) | 无 | **免 root、不用 IOReport**,stats 同款(§12);键名属半私有,读不到就空白卡 |
| 神经网络引擎(系统级) | IOReport "Energy Model" 通道用户态读 `ANE*` 能量差分 → 功率(W),按芯片型号最大功耗归一化 | 无 | stats 同款(§12),自带 M1–M6 最大功耗表;**原始值是无量纲整数,必须按 `IOReportChannelGetUnitLabel`(mJ–pJ)换算再差分**,否则差几个数量级(GPU/reader.swift:348-362);首读返回 0(无基线);IOReport 半私有,失败静默降级 |
| GPU/能耗/每.App | IOReport task/energy 通道(半私有,需 root);或 `powermetrics` | root | P3,CPU 归因不需要它 |
| 温度/风扇 | SMC(社区文档完备) | 无 | P2 |
| 声音 | CoreAudio 设备音量/静音/设备列表 | 麦克风权限(输入电平) | P2;系统音量层有 stats 的 Kit 实现可参照;**每 App 音量/输入电平三个参考库均无实现**,先探针验证 macOS 14+ 进程音频 API 再排 |
| 蓝牙外设电量 | 三源合并:IORegistry HID(Apple 外设 `BatteryPercent`)→ `com.apple.Bluetooth` plist 缓存(免权限)→ CoreBluetooth GATT 电池服务 0x180F | 蓝牙权限(CoreBluetooth) | P2;**单靠 IOBluetooth 拿不到 BLE 外设电量**(stats 五源合并的教训);plist 缓存里电量值 1 要当 100 解释(statsref Bluetooth/readers.swift:339-341) |
| 容器 | docker.sock(`/var/run/docker.sock`,OrbStack 同款)HTTP API 或 `docker ps` 子进程 | 无 | P2 |
| 监听端口 | `libproc PROC_PIDLISTFDS`+`PROC_PIDSOCKETINFO` 或 `lsof -iTCP -sTCP:LISTEN` | 自有进程 | dev server finder |

**权限结论**:监控你自己拉的进程(rustc/vitest/OrbStack 帮你跑的容器在宿主侧
也是你的用户)用户态全够;系统级全量视角与每 App 能耗/GPU 才需要 root helper
—— 与 Vitals 的"optional helper" FAQ 完全一致。helper 排到 P3,前两个阶段
(P1 公开 API、P2 半私有免 root)都不需要它。

## 5. 存储与历史(30 天)

```sql
CREATE TABLE sample_min (          -- 1 分钟 rollup, 保留 7 天
  ts INTEGER, group_id TEXT,
  cpu_avg REAL, cpu_max REAL,      -- 组内进程求和后取 avg/max
  mem_max INTEGER, procs INTEGER,
  disk_r INTEGER, disk_w INTEGER
);
CREATE TABLE sample_hour (         -- 1 小时 rollup, 保留 30 天, 同构
);
CREATE TABLE lineage (             -- 出生登记, 防孤儿断链
  pid INTEGER, uniqid TEXT, parent_chain TEXT,
  argv TEXT, cwd TEXT, first_seen INTEGER
);
CREATE TABLE groups (              -- group_id → 展示名/图标/类别/项目
);
-- WAL 模式; ~80 组 × 1440 行/天 × 7d ≈ 80 万行 + 小时表, SQLite 无压力
```

5s 原始值只留内存环形缓冲(1h),不落盘。"写入今天多少 GB"这类累计卷视图:
磁盘 = rusage diskio 求和累计,网络 = NET_RT_IFLIST2 差分累计,P1 落 SQLite
一并做。

## 6. 告警引擎(v1 规则即可)

```
规则 = { group 匹配器, 指标, 阈值, 持续时长, 冷却期 }
例: 任一组 cpu_sum > 300% 持续 10min → 通知
    新组出现且 mem > 2GB → 通知
    dev server idle > 24h → 通知 "可释放 X GB, 端口 3000/4321..."
迟滞: 进入阈值连续 3 次采样才触发; 退出需连续 6 次低于阈值-20%
```

## 7. 技术选型(给你定制的推荐)

**推荐:Tauri 2 + Rust 后端 + React/shadcn/TanStack UI** —— 用你最能打的栈:

- `sysinfo` crate 在 macOS 覆盖 ~90%:每进程 cpu/memory/parent/**cmd()**/**cwd()**
  (内部就是 libproc);缺的部分补 20 行 FFI(下方代码)。
- 菜单栏 = Tauri tray + popover 窗口;通知 = tauri-plugin-notification;
  SQLite = rusqlite;全部单二进制。
- UI 你直接复用 shadcn 组件 + TanStack Query(轮询后端 emit 的事件流)。
- 代价:WKWebView 常驻 ~50-100MB 内存。可接受。

**备选:纯 Swift + SwiftUI**(`MenuBarExtra`),最原生、占用最低(<30MB),
Darwin API 零 FFI 直接调;代价是 UI 开发速度对你更慢。若最终在意常驻开销再迁。

```rust
// 补 sysinfo 缺口的 libproc FFI 示例: 拿 cwd
#[repr(C)]
struct VnodeInfoPath { /* stat + path ×3, 见 libproc.h vnode_info_path */ }
extern "C" { fn proc_pidinfo(pid: i32, flavor: i32, arg: u64, buf: *mut u8, size: i32) -> i32; }
const PROC_PIDVNODEPATHINFO: i32 = 9;

fn cwd_of(pid: i32) -> Option<String> {
    let mut buf = vec![0u8; 4096];
    let n = unsafe { proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, buf.as_mut_ptr(), buf.len() as i32) };
    (n > 0).then(|| parse_c_path(&buf)).flatten()
}

// 采样主循环
loop {
    procs.refresh_processes(ProcessRefreshKind::everything());
    let snap: Vec<ProcSnap> = procs.processes().map(|(pid, p)| ProcSnap {
        pid, ppid: p.parent(), exe: p.exe(), cmd: p.cmd().join(" "),
        cwd: cwd_of(*pid as i32), // 或 p.cwd()
        cpu: p.cpu_usage(), mem: p.memory(), disk: p.disk_usage(),
        start: p.start_time(),
    }).collect();
    let groups = group(&snap, &mut lineage_cache, &project_roots);
    ring.push(groups.clone());
    if now - last_flush > 60 { rollup_and_store(&ring); }
    app_handle.emit("snapshot", &groups)?;   // UI 订阅
    if window_open { sleep(1s) } else { sleep(5s) }
}
```

归组伪代码(§3 的实现):

```
fn group(snap, cache, roots):
  for p in snap:
    p.app   = bundle_of(p.exe) 或 cache.lookup_parent_app(p) 或 null
    p.proj  = match_path(p.cwd, roots) ?? match_path(p.cmd, roots)
  rollup: for p in snap where p.app==null:
    p.app = walk_parent_chain(p, snap, cache)   # 出生时已缓存, 活链优先
  classify: dev_tool(p.cmd) → "质量门禁/构建/测试" 标签
  merge → HashMap<GroupId{app, proj, class}, Agg>
```

## 8. dev server finder(v1 就值得做)

- argv 正则:`vite|next dev|webpack(-dev-server)?|tsc .*--watch|vitest|jest|pytest|manage\.py runserver|bun run dev|cargo watch`
- 收集其 LISTEN 端口 + 内存 + 最近 CPU;idle 判定 = 近 N 分钟 cpu_avg ≈ 0
- 卡片:"3 个 dev server 在跑但闲置,可释放 1.37 GB,端口 3000/4321/8000 [全部停止]"
  (停止必须确认——参考 Vitals 的原则:不主动杀,只在你确认后杀)

### 8.1 项目可回收产物扫描(P1 候选)

同族功能,点子来自 mole 的 "Purge"(§12):在已配置的项目根下找
`node_modules`/`target`/`build`/`dist` 等可重建目录,按项目汇总——
项目卡片给一行"可回收 3.2 GB(node_modules × 5)",告警引擎可出
"这个项目半个月没动,产物占 X GB"。只读盘点,删不删永远由人确认,
与 dev server finder 同一原则。实现用 `getattrlistbulk` 目录遍历,
扫描限项目根、限深度、后台低优先级,不进采样轮。

## 9. MCP server(P3,但这是对你最有价值的一块)

以 Tauri sidecar 或独立小二进制暴露 stdio MCP:

- `why_cpu_high()` → 直接返回 §3.3 那段归因文本(带 lineage 面包屑)
- `top_groups(metric, n)` / `group_detail(group_id)` / `history(group_id, range)`
- 场景闭环:以后你在 agent 会话里问"为什么 CPU 100%",agent 调一次
  `why_cpu_high()` 就能拿到"octok-client 质量门禁 445% + WaifuX 55%",
  而不是再跑一遍 ps 猜。Vitals 官方 roadmap 也才刚规划这块。

## 10. 分期落地(个人项目节奏)

进度:P0 / P0.5 / P0.6 已完成(2026-10)—— 采样器 + 三层归组 + 菜单栏
CPU/内存双徽章 + popover 分组卡 + 主窗口 tab + kill 组 + 项目根配置,
215 个测试绿。按"权限门槛"分阶段推进,免 root 的先做:

| 阶段 | 内容 | 预估 |
|---|---|---|
| P0 ✅ | 采样器 + 三层归组 + 菜单栏 popover + 项目根配置 + kill 组 | 已完成 |
| P1 历史 + 基础传感器 | SQLite 历史 + sparkline + 告警 + dev server finder + 诊断报告复制;磁盘卡、网络卡(系统总量)、电池卡、Memory by Type;项目可回收产物扫描(§8.1,候选);菜单栏徽章可配置。全部公开 API,零新权限 | 2-3 个周末 |
| P2 系统传感器(免 root) | GPU 卡(IORegistry PerformanceStatistics)+ 神经网络引擎卡(IOReport Energy Model)+ 温度/风扇(SMC)+ 声音(CoreAudio)+ 蓝牙电量(IOBluetooth)+ 容器 tab(docker.sock)——免 root 路径全部经 stats 源码证实 | 2-3 个周末 |
| P3 深度 + 集成(需 root/按兴趣) | root helper(SMAppService)系统全量视角 → 每 App 能耗/GPU/网络归因;MCP server;Agents 用量卡(解析本地 AI 会话用量) | 按兴趣 |

风险与对策:
- **隐私/合规**:全程本地,无网络,公司机友好。
- **API 退化**:libproc 系列虽老但稳定(Vitals 自己也依赖它们);把
  采集层隔离成 trait,便于将来 macOS 大版本变化时换实现。
- **半私有 API(IOReport/SMC)无兼容承诺**:macOS 大版本更新可能改通道名
  或结构体布局;P2 每张卡做"读取失败静默降级为空白卡",不崩主程序,升级
  macOS 后先跑采集探针再发版。
- **采样开销**:合盖 5s + 开窗 1s 自适应,已在 §2 预算内;心跳型传感器
  (网络吞吐等)沿用同一节奏;**低频/事件型传感器(容量对账、SMART、电池)
  单独分档调度**,不塞进 1s 心跳(调研结论,§12);所有差分指标唤醒后清基线。

## 11. 与 Vitals 的关系(全功能复刻 + 两处做深)

2026-10-15 拍板:**完整复刻 Vitals 的全部传感器面板**(磁盘、网络、GPU、
神经网络引擎、电池、声音、蓝牙、容器、温度风扇),不按"别做全功能克隆"
收缩范围;排期见 §10。仍然砍掉的只剩:多语言、license 体系、App Store
上架(自用 sideload,不需要)。

复刻之外做深两件 Vitals 没做好的:**项目/agent 会话归因**(§3.3)+
**MCP**(§9)+ **质量门禁检测**(cargo/vitest/clippy 识别为"agent 正在
工作",而不是一串陌生进程)。这正好补上你工作流里"AI 拉起一堆编译测试,
黑盒跑 20 分钟"的观测盲区。

## 12. 参考实现(2026-10-15 调研,本机已克隆读过)

| 仓库 | 是什么 | 拿什么 | 协议约束 |
|---|---|---|---|
| [petal](https://github.com/henrydennis/petal) | Rust+GPUI 磁盘空间探索器(旭日图),全盘 ~600 万文件 25s | **代码级参考**:`src/disk.rs` 的 `startup_layout()` APFS 容器级容量算法、purgeable 两 key 差值、`fs_snapshot_list` 快照枚举,照此翻译成 Swift 做 P1 磁盘卡。注意它同时回答了"为什么 naive statfs 不准" | **MIT**,可翻译代码,文件头注明来源 |
| [stats](https://github.com/exelban/stats) | Swift 菜单栏监视器,42.6k star,模块与本方案 P1/P2 传感器一一对应 | **代码级参考(P2 主参考)**:GPU 利用率 = IORegistry `kIOAcceleratorClassName` → `PerformanceStatistics`("Device Utilization %" 等),免 root 不用 IOReport;神经网络引擎 = IOReport "Energy Model" 用户态 ANE 能量差分 + 每芯片最大功耗表(`Modules/GPU/reader.swift`);SMC 温度风扇 = `SMC/smc.swift` 可直接移植;网络 `NET_RT_IFLIST2`、电池 IOPowerSources 均与 §4 互相印证 | **MIT**,可移植代码,注明来源 |
| [mole](https://github.com/tw93/Mole) | Go 终端版 CleanMyMac(清理/卸载/磁盘分析/状态仪表盘) | **只拿点子**:项目可回收产物扫描(§8.1)、SMART 可选字段、APFS free 分层修正(独立印证 petal 结论)。**实现一律不学**——数据层全是起子进程 + 正则(pmset/system_profiler/diskutil/powermetrics),常驻监视器场景是反模式,GPU 那条还要 root | **GPL-3.0**,不抄代码、不翻译(翻译也算衍生);点子/算法思路不受版权限制 |
| Vitals 本体 | 闭源商用监视器 | UI 形态、每指标强调色、数字口径的**行为对齐基准** | 闭源,只对齐行为,不看其代码 |

逐传感器的实现细节、防御点清单与 9 条待本机探针验证的开放问题
(IOReport 通道可用性、PerformanceStatistics 键名、purgeable 双口径、
SMC 权限门槛、OrbStack socket 路径等)见
**`docs/research/sensor-impl-comparison.md`**(2026-10-15,file:line 级引用)。

架构结论(同一份调研):P1 引入薄 `SensorProvider`(cadence + snapshot +
lastGood,ADR-0003 的扩展点),不抄 stats 的 Reader 全家桶(不带走它的
DB-in-Reader/远程上报/config.plist 动态模块);CPU/内存/网络吞吐等心跳型
指标留在 `Sampler` 单一循环节拍里,磁盘容量对账、SMART、电池、容器这类
低频/事件型传感器由独立调度器按各自 cadence 驱动;所有差分型指标在系统
唤醒后清基线/丢首轮,否则 UI 出巨刺。
