# Pulse — 菜单栏"App 视角"系统监视器技术方案

> 目标:做一个 Vitals (vitalsmac.com) 的个人版。核心诉求不是看数字,而是回答
> **"到底是什么在占用我的 CPU"** —— 比如 2026-10-12 那次:load 52,
> 真相是 octok-client 两个 worktree 同时跑质量门禁(cargo test + vitest --coverage)
> + WaifuX 常驻白烧 60% + OrbStack VM 86%。活动监视器只会给你 1000 行进程列表。

---

## 1. Vitals 拆解:它做了什么,哪些能复刻

| 功能 | 原理 | 复刻难度 |
|---|---|---|
| 1000 进程 → 60 个 App | 进程归属引擎(本方案 §3,核心) | ★★★ 这是产品壁垒 |
| 30 天历史 | 本地 SQLite + 降采样 | ★★ |
| CPU/内存/磁盘/网络 每.App 汇总 | libproc 公开 API | ★ |
| GPU / 能耗 每.App | IOReport task 通道,需 root,半私有 | ★★★ 可推迟到 v2 |
| 发现被遗忘的 dev server | argv 模式匹配 + 监听端口枚举 | ★★ |
| 异常告警 | 阈值 + 迟滞的规则引擎 | ★ |
| 菜单栏常驻,合盖采样 0.1% 单核 | 5s 慢采样 / 打开时 1s | ★ |
| 可选 root helper 读系统进程 | SMAppService daemon + XPC | ★★ v2 |
| Roadmap: MCP server 供 AI 询问 | 顺手做,对 AI coding 用户价值极大 | ★ |

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
│  └─ MCP server (v2): why_cpu() / top_groups()               │
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
| 网络/进程 | 无公开 API。`nettop -P -L`(JSON 流)子进程解析,或 v2 再做 | 无 | |
| GPU/能耗/每.App | IOReport task/energy 通道(半私有,需 root);或 `powermetrics` | root | v2,CPU 归因不需要它 |
| 温度/风扇 | SMC(社区文档完备) | 无 | 可选 |
| 监听端口 | `libproc PROC_PIDLISTFDS`+`PROC_PIDSOCKETINFO` 或 `lsof -iTCP -sTCP:LISTEN` | 自有进程 | dev server finder |

**权限结论**:监控你自己拉的进程(rustc/vitest/OrbStack 帮你跑的容器在宿主侧
也是你的用户)用户态全够;系统级全量视角才需要 root helper —— 与 Vitals 的
"optional helper" FAQ 完全一致。v1 不做 helper。

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

5s 原始值只留内存环形缓冲(1h),不落盘。写入今天多少 GB 这类"卷"视图
另用 `sysctl vfs` / `DKIO` 差分,非核心可后置。

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

## 9. MCP server(v2,但这是对你最有价值的一块)

以 Tauri sidecar 或独立小二进制暴露 stdio MCP:

- `why_cpu_high()` → 直接返回 §3.3 那段归因文本(带 lineage 面包屑)
- `top_groups(metric, n)` / `group_detail(group_id)` / `history(group_id, range)`
- 场景闭环:以后你在 agent 会话里问"为什么 CPU 100%",agent 调一次
  `why_cpu_high()` 就能拿到"octok-client 质量门禁 445% + WaifuX 55%",
  而不是再跑一遍 ps 猜。Vitals 官方 roadmap 也才刚规划这块。

## 10. 分期落地(个人项目节奏)

| 阶段 | 内容 | 预估 |
|---|---|---|
| P0 周末版 | 采样器 + 三层归组 + 菜单栏 popover Top-5 + 项目根配置 + kill 组 | 1-2 天 |
| P1 | SQLite 历史 + sparkline + 告警 + dev server finder + 诊断报告复制 | 1-2 个周末 |
| P2 | root helper(SMAppService)系统全量视角;IOReport 能耗/GPU;MCP server | 按兴趣 |

风险与对策:
- **隐私/合规**:全程本地,无网络,公司机友好。
- **API 退化**:libproc 系列虽老但稳定(Vitals 自己也依赖它们);把
  采集层隔离成 trait,便于将来 macOS 大版本变化时换实现。
- **采样开销**:合盖 5s + 开窗 1s 自适应,已在 §2 预算内。

## 11. 与 Vitals 的差异化(别做全功能克隆)

砍掉:每.App 音量控制、蓝牙电量、多语言、license 体系(自用不需要)。
做深:**项目/agent 会话归因**(§3.3)+ **MCP**(§9)+ **质量门禁检测**
(cargo/vitest/clippy 识别为"agent 正在工作",而不是一串陌生进程)。
这正好补上你工作流里"AI 拉起一堆编译测试,黑盒跑 20 分钟"的观测盲区。
