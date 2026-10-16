# Vitals 样式参考与差距分析(给 Pulse 自己实现用)

> 目的:把 Vitals (vitalsmac.com) 的视觉与信息架构拆到"能直接落 SwiftUI"的程度,
> 对照 Pulse 现状给出差距清单。工作文档,不是像素级规范。
>
> **读图方法说明(如实记录)**:任务指定的视觉模型工具 `mcp__4_5v__analyze_image`
> 在本次会话不可用(工具列表中不存在)。按预案退化:以官网 HTML/CSS/JS 的结构化
> 提取为骨架,三张截图用 Read 工具**自行目视**解读,视觉结论均标注来源,目视结论
> 与 HTML 冲突时以 HTML 为准。
>
> **素材与出处约定**(下文用短代号引用):
> - `OG` = /tmp/vitals_og_home.png(2400×1260 官网主图,左侧大弹窗 + 右侧紧凑弹窗)
> - `SHOT1` = /tmp/vitals_shot1.jpg(960×594,即官网 /love/shots/ivandotge.jpg,主窗口浅色)
> - `SHOT2` = /tmp/vitals_shot2.jpg(960×890,即 /love/shots/lucian_forseti.jpg,暗色 Volume tab)
> - `HTML` = /tmp/vitals_site.html(官网首页,vitalsmac.com,510K)
> - `PANE-*` = 从 HTML 提取的 11 个 tab 面板 DOM(id="pane-<tab>"),见各节标注
> - `CSS` = vitalsmac.com/_astro/_guide_.CnFNrVbF.css + index.GL3ufeHm.css + 首页内联 `<style>`
> - `JS` = 首页 demo 脚本 index.astro…DhGj8kWV.js(模拟数据 + 图表渲染逻辑)
> - `Pulse/<file>:<line>` = 我们自己的代码
>
> 本文档不改任何应用代码。

---

## 1. 设计语言总结

### 1.1 配色(浅 / 深双套,CSS `:root` / `@media(prefers-color-scheme:dark)`)

中性色(CSS 变量 → 值):

| 变量 | 浅色 | 深色 | 用途(HTML 中的实际用法) |
|---|---|---|---|
| `--bg` | `#ffffff` | `#131315` | 页面/弹窗外底 |
| `--raised` | `#ffffff` | `#1a1a1d` | 弹窗本体底色(`data-window` 容器 `bg-raised`,HTML) |
| `--card` | `#f5f5f7` | `#1f1f22` | 卡片底(`.card`)——**与底色只差一档**,靠 1px 描边补分界 |
| `--card-hi` | `#e8e8ed` | `#27272b` | 卡片内强调底、环形图"剩余/Other"段(PANE-overview) |
| `--ink` | `#1d1d1f` | `#f5f5f7` | 主文字/大数字 |
| `--ink-2` | `#6e6e73` | `#a1a1a6` | 次要文字、标签 |
| `--ink-3` | `#a1a1a6` | `#6e6e73` | 三级文字、图标灰 |
| `--line` | `#00000014`(黑 8%) | `#ffffff1a`(白 10%) | 分隔线、图表网格线(`.chart .grid`) |
| `--accent` | `#007aff` | `#0a84ff` | 交互强调(与系统蓝一致) |
| `--red` | `#e0352b` | — | 危险色 |

窗口投影(CSS `--shadow`,窗体浮起全靠它):
`0 30px 80px -20px #0f1e4647, 0 0 0 1px #00000014`(浅)/ `…#000000b3, 0 0 0 1px #ffffff1a`(深)。
即:**大柔影 + 1px 半透明描边环**,不用 blur 材质(官网弹窗是不透明的 `bg-raised`,HTML `data-window` 容器)。

**每指标一个强调色(tint)**——整套 UI 的灵魂(CSS `:root`):

| 指标 | 浅色 | 深色 |
|---|---|---|
| CPU | `#2a78d6` | `#3987e5` |
| Memory | `#4a3aa7` | `#9085e9` |
| Neural | `#4a3aa7` | `#9085e9`(与 Memory 同色) |
| Disk | `#eda100` | `#c98500` |
| Network | `#1baf7a` | `#199e70` |
| GPU | `#e87ba4` | `#d55181` |
| Battery | `#008300` | `#2fa83a` |
| Projects | `#eb6834` | `#d95926` |
| Sound | `#c2379b` | `#d955b3` |
| Bluetooth | `#0891b2` | `#22a8cc` |

tint 的渗透方式(关键机制,CSS + PANE-* 反复出现):
当前 tab 给根元素挂 `tint-<metric>` 类 → 子元素统一用 `var(--tint)`,于是**图标徽章、
选中 tab、chip、进度条、图表线、环形图全变为该指标色**。派生色一律用
`color-mix(in srgb, var(--tint) N%, transparent | var(--card))`:
- 选中 tab 底 = tint 15%(`.tab[aria-selected=true]`)
- 徽章底 = tint 16%(`.badge`)
- chip 底 = tint 14%(`.chip`)
- meter 轨道 = tint 14%(`.meter`)
- strip 轨道 = tint 9%(`.strip`)
- 单色环形梯度 = tint 与 card 按 100/83/66/49% 混合(PANE-overview "Memory by App")
- Projects 告警横幅底 = tint 11%(PANE-projects)

### 1.2 字体

- 正文:`-apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", …`(CSS body)。
- **所有数字类**:两种做法并存(CSS):
  - `.tnum { font-variant-numeric: tabular-nums }`——表格数值(应用排行表 `text-[12px] font-semibold`)用普通字体 + 表格数字对齐;
  - `.figure { font-family: var(--font-rounded)=ui-rounded/"SF Pro Rounded"; font-weight:700; tabular-nums; letter-spacing:-.02em; line-height:1 }`——**大数字专属:圆体、加粗、负字距**,这是 Vitals 观感最 distinctive 的一笔(CSS `.figure`;SHOT1 的 48%/51,06 GB 即此样式)。
- 字号节奏(HTML Tailwind 任意值,全部来自真实 DOM):
  - 详情 tab 主数字 `text-[44px]`(PANE-cpu 主卡);Overview 卡主数字 `text-[34px]`;紧凑行数值 `text-[22px]`;主卡次级统计 `font-rounded text-[18px] font-semibold`(rounded 字体也用在数字上,PANE-cpu);
  - 小标签 `text-[10.5px]~[12px]` `text-ink-2`,数值 `text-[12px] font-semibold`;
  - tab 按钮 12.5px/500(CSS `.tab`);chip 12px/600。
- 单位(%、GB、kB/s)一律小一号、基线对齐:`flex items-baseline gap-1.5`,数值大字 + 单位小字(HTML 所有 `figure` 容器)。
- 本地化:SHOT1 是德语区截图,小数逗号(`51,06 GB`)——说明数字走系统 Locale 格式化。

### 1.3 间距与圆角

- 卡片内边距 `p-4`(16px,Overview 卡)/ `p-5`(20px,详情主卡);卡间距 `gap-4`(16px)或 `.cards{gap:8px}`(紧凑网格);弹窗内容区 `p-4~5`(HTML)。
- 圆角:弹窗本体 `rounded-[16px]`;卡片 18px(`.card`);官网面板 28px(`.panel`);徽章 7px(`.badge`);meter 3px;strip 容器 8px、柱条仅上圆角 2px;tab/chip 全圆 `999px`(CSS)。
- 图标徽章 22×22(`.badge`)、排行表应用图标 22/26px(PANE-cpu 表)、紧凑行微图 26×14(HTML `part-graph h-[14px] w-[26px]`)。

### 1.4 材质与层级

- 弹窗:不透明 `--raised` 底 + 大投影 + 1px 描边(HTML `data-window`),**无毛玻璃**。
- 卡片:平涂 `--card`,无描边无投影,靠与窗底的微差分界;层级只有"窗 > 卡 > 卡内元素"三级。
- 彩色元素全部是"低饱和 tint 底 + 纯 tint 前景"的半透明配方(color-mix),因此浅深两套都成立。
- 暗色:`SHOT2`(暗色 Volume tab)验证了暗色下一整套 token 生效,布局不变。

---

## 2. 信息架构

### 2.1 两种窗型

**弹窗(菜单栏 popover,OG)**:
- 顶栏:11 个图标 tab(无文字,`title` 提示):Overview / CPU / Memory / Disk / Network / GPU / Neural / Battery / Sound / Bluetooth / Projects(HTML tablist,`data-tab` ×11)。
- Overview 头:标题 "Overview" + 右侧 `⏱ Up 6d 4h`(OG)。
- 大尺寸变体:双列指标卡网格 + "Busiest Right Now" 排行卡 + 底部操作排 `Open Vitals`(宽主按钮)+ 齿轮 + `Quit`(电源图标)(OG 左)。
- 紧凑变体(≈340pt):单列行——图标 + 名称 + 26×14 微型走势条 + 次要文案 + 右对齐数值(OG 右;HTML 紧凑行 `part-graph`/`part-value` 类)。**注意:Pulse 现在的弹窗组卡 ≈ 这个紧凑行**。
- 底部操作排与 Pulse 现状(DashboardView.swift:61-85)同构:一个宽主按钮 + 齿轮 + 退出。

**主窗口(SHOT1)**:
- 顶部工具条:红绿灯 + "Vitals" + **药丸 tab 条**(图标+文字,8 个可见:Overview / CPU / Memory / Disk / Network / GPU / Battery / Projects;该用户窗口未显示 Neural/Sound/Bluetooth——与设备能力/连接状态相关,官 demo 是 11 个)+ 右侧齿轮(SHOT1)。
- 内容头:`Overview` 大标题 + 设备副标题 `Apple M1 Max · 10 cores · 64 GB`;右侧图表样式切换(柱/线两个小图标钮)+ `Export` 按钮(SHOT1)。
- 内容:3 列指标卡网格(16px gap)→ "Worth a Look" 状态区 → "Right Now" 环形卡区(SHOT1;HTML PANE-overview 同构)。
- 卡片可点下钻:Overview 每张指标卡本身是按钮,`data-goto="<tab>"` 跳对应 tab(HTML PANE-overview)。

### 2.2 Overview tab(PANE-overview)

第一网格 6 张指标卡(结构完全同构,每张 = 可点按钮):
| 卡 | 标签行 | 主数字 | 三列小统计 | 底图 |
|---|---|---|---|---|
| CPU `tint-cpu` | 图标徽章+名+chevron | `27%`(34px) | User 19% / System 8% / **Average Today 36%** | 44 柱 strip |
| Memory `tint-memory` | 同上 | `52.63 GB` + 绿色 `✓ Normal` chip | App(colored dot)23.43 GB / Wired 5.37 GB / Compressed 23.82 GB | strip |
| GPU `tint-gpu` | 同上 | `60%` | Memory 1.69 GB / **Average 32% / Peak 95%** | strip |
| Disk `tint-disk` | 同上 | `479.72 GB` | Reading / Writing / **Written Today 38.9 GB** | strip |
| Network `tint-network` | 同上 | `12 kB/s` | Uploading / **Today 4.4 GB / Last 7 Days 48.3 GB** | strip |
| Battery `tint-battery` | 同上 | `64%` | Remaining 2h 46m / Power Draw 12.6 W / Health 76% | strip |

第二网格 3 张环形卡:
- **Memory by Type**(`tint-cpu`):环形分段直接用指标色(App=cpu / Wired=projects / Compressed=network / Cached=ink-3 / Free=card-hi),环心 `82% in use`,右侧图例含色点+GB 数(PANE-overview)。
- **Memory by App**(`tint-memory`):**单色梯度环形**(tint 100/83/66/49% → card,第五段 Other=card-hi),每段图例带应用小图标,环心 `59.25 GB all apps`。
- **Power by App**(`tint-battery`):同上,环心 `1.7 W all apps`。

### 2.3 CPU tab(PANE-cpu)

1. **主卡**(全宽,`grid-cols-[170px_1fr] p-5`):左列 `Now` 标签 + `27%`(44px)+ 右下两行 `Average today 36%` / `Load 3.41`;右列全宽**面积折线图**(56 点)。
2. **2×2 统计卡**:User(19%,副文 "Your apps")/ System(8%,"macOS")/ Cores(12,chip `8 P` `4 E`)/ Top App(应用图标+名,右值 18.2% + 趋势箭头)。
3. **应用排行卡**:表头 `App | CPU`;行 = 图标 + 名称 + `96 processes` 副文 | 右侧数值 + **meter 条**(宽度按榜首归一)。

### 2.4 Memory tab(PANE-memory)

1. 主卡:`In use of 64 GB` + `52.63 GB` + 绿 chip `✓ Normal`;右侧两行 `Free 11.37 GB` / `Swap 0 MB`;面积图。
2. 2×2 统计卡:App 23.43 GB(下附 meter 37%)/ Wired 5.37 GB(meter 8%)/ Compressed 23.82 GB(meter 37%)/ Top App(20.59 GB + 箭头)。
3. 应用排行卡(同 CPU 模板,列头 `App | Memory`)。

### 2.5 Projects tab(PANE-projects)——无图表,全是行与 chip

1. **告警横幅卡**:底色 tint 11%,左图标 + `4 dev servers are running but idle` + 副文 `Stopping them frees 1.37 GB and ports 3000, 4321, 4322, 8000` + 右侧**实心 tint 按钮 `Stop All…`**。
2. 项目行 ×N:文件夹徽章 + 项目名 + 副文(运行时 `node`/`python`/进程数);中部 chip 组——端口 chip(如 `4322`)+ 状态 chip(`✓ working` 绿 / `up 3 days, barely used`、`idle 2 hours` 灰 `--tint:var(--ink-2)`);右对齐内存 `458 MB`(tnum)。

### 2.6 其余 tab(结构归入图表词汇表,完整卡片清单如下)

- Disk(PANE-disk):主卡(Free of 994.66 GB,Used/Written today)+ 面积图 + Reading/Writing/Volumes(chips:盘名)/Top App + 排行(`App | Writing`)。
- Network(PANE-network):主卡(Downloading 12 kB/s,Today/Last 30 days)+ 面积图 + Uploading/Last 7 Days/Interface(Wi-Fi,副 en0)/Top App + 排行(`App | Downloading`)。
- GPU(PANE-gpu):主卡(60%,Average/Peak)+ 面积图 + Memory/Average/Peak/Top App + 排行(`App | GPU`)。
- Neural(PANE-neural):主卡(16-core Neural Engine 2%,Average/Peak)+ 面积图 + Memory Traffic/Average/Peak/Top App + 排行(`App | Neural Engine`)。
- Battery(PANE-battery):主卡(On battery 64%,Remaining/Cycles)+ 面积图 + Power Draw/Health(meter 76%)/Temperature/Top App + 排行(`App | Power`)。
- Sound(PANE-sound,SHOT2):**无图表**。Output 卡(输出设备名 + 音量 slider + 64%);应用表 `App | Status | Volume | Level%`——Status=Playing/Silent,Volume=可拖 slider,Level=右对齐百分比;Muted 态图标变化。
- Bluetooth(PANE-bluetooth):**无图表**。汇总卡(`3 connected` + 最低电量一句话说明 + meter 电量,低电时 meter 变 disk 黄)+ 设备表 `Device | Kind | Battery(meter)| Level%`,耳机拆 Left/Right/Case 三行,低电行 meter 用 `var(--disk)` 警示色。

---

## 3. 图表词汇表(Swift Charts 构件候选)

1. **strip 微柱历史图**(Overview 卡底、紧凑行 26×14)
   - 数据:最近 N 个采样值归一化高度(CSS `.strip`;JS:`data-bars=44`,44 根,高度=value*100%,旧值以 2% 垫底)。demo 节奏 2s/根(JS `U=2000`)。
   - 形态:全宽 ~36px 高(HTML `h-9`);柱条上圆角 2px、间距 2px;容器 tint 9% 轨道;柱 tint 纯色;高度变化 0.6s 缓动(CSS `.strip i`)。
   - 无轴、无标签——纯"形状即数据"。
   - 变体:紧凑行 26×14、`gap-px`、无轨道(HTML `!gap-px !rounded-none !bg-transparent`)。
2. **面积折线图**(详情 tab 主卡)
   - 数据:56 点历史(JS `v=56`);viewBox 100×100 `preserveAspectRatio=none`(HTML PANE-cpu)。
   - 画法:折线 stroke tint 2px、`vector-effect:non-scaling-stroke`;线下面积 = 线性渐变 tint 32%→0(HTML `<linearGradient>`);4 条水平网格线(y=8/37/66/96,即 25% 步进)stroke `--line`(CSS `.chart .grid`)。
   - **无坐标轴刻度、无数值标签**(OG/SHOT1 同)。
3. **meter 进度条**(Memory 分解、Battery Health、排行行内占比、蓝牙电量)
   - 数据:占比 0–1;排行行按榜首归一(JS `k[...] = v/max`)。
   - 形态:高 6px、圆角 3px;轨道 tint 14%;填充 tint 纯色;宽度过渡 0.6s `cubic-bezier(.2,.7,.2,1)`(CSS `.meter`)。低电量等告警可换色(蓝牙 42% 用 disk 黄,PANE-bluetooth)。
4. **环形图 donut**(Overview 右列)
   - 数据:构成占比;SVG `circle stroke-dasharray` 分段(PANE-overview)。
   - 配色两套:构成分类用**各指标色**(by Type);排名类用**单色梯度**(by App/Power:tint 与 card 100/83/66/49% 混合,Other=card-hi)。
   - 环心:大数字 + 两字说明(`82% in use`)。环宽 stroke 13/50(viewBox 100)。
5. **大数字 figure**(所有卡的主值)
   - 圆体 700、tabular-nums、字距 -0.02em、line-height 1;单位小字基线对齐(§1.2)。
6. **chip 状态徽章**(✓ Normal / working / idle 2 hours / 端口号)
   - 全圆 pill,tint(或 ink-2)14% 底 + 同色文字,可带 10px 图标(CSS `.chip`;PANE-projects)。
7. **滑杆 slider**(Sound tab,SHOT2)
   - 粗圆杆 + 白色圆 thumb,填充 tint;行内可拖(SHOT2 粉色滑杆)。Sound tab 已纳入复刻范围(tech-design §11,2026-10-15 起全功能复刻),形态照此实现。

---

## 4. 与 Pulse 的差距分析

Pulse 现状基线(已读):
- 弹窗 `Pulse/DashboardView.swift:28-56`:头部(Pulse + 系统 CPU 负载,340pt 宽,:54)→ 全部组卡滚动列表 → 底部操作排(:61-85,打开主窗口 + 退出——与 Vitals 弹窗 footer 同构)。
- 组卡 `Pulse/DashboardView.swift:166-206`:图标(26px,:228-231)/ 名称 / N 进程 / CPU%(title3 monospacedDigit)/ 内存(caption)/ chevron / 结束按钮;卡底 `.quaternary` 圆角 10(:200);**唯一彩色 = 孤儿橙**(:262-267,与 GLOSSARY.md:47 的"孤儿橙色高亮"口径一致)。
- 主窗口 `Pulse/MainWindowView.swift:25-47`:全部组 + 展开后 `SortableProcessTableView`(表头 CPU%/内存排序,`Pulse/ProcessTableOrder.swift:26-33` 点同列升降、换列降序)。
- 采样现状:`Pulse/SystemMonitor.swift:18-24` 实时有 `systemCPULoad`、`allGroups`(组 CPU%、内存、进程数)、`drilldown`(每进程 CPU%/内存);采样节奏弹窗关闭 5s/打开 1s(GLOSSARY.md:9-11)。
- **全仓库无 `import Charts`,无任何历史缓冲**(`rg "import Charts"`、`rg "RingBuffer|history" Pulse/` 均为空,本次执行确认)——图表与走势所需的"过去 N 个采样"目前不存在。
- 尚未实现、但已全部纳入 roadmap 的范围(tech-design §10,2026-10-15 起 P1–P3 全功能复刻):磁盘/网络/电池系统卡 + Memory by Type(P1)、30 天 SQLite 历史(P1)、告警引擎(P1 §6)、dev server finder(P1 §8)、GPU/神经网络/温度风扇/声音/蓝牙/容器(P2)、每 App 能耗与 GPU + MCP(P3)。

### 4.1 Vitals 有、Pulse 没有(按用户可见影响排序)

1. **图表全缺**:Vitals 每张卡都有近期走势(44 柱 strip / 56 点面积图),Pulse 全是当轮静态数字。这是"vitals 有图表"观感差的最大来源。
2. **无指标维度**:Pulse 只回答 CPU(+内存列);Vitals 有 11 个指标 tab、每 tab 完整页面。
3. **无强调色体系**:Pulse 全灰 + 孤儿橙;Vitals 每指标一色并渗透到徽章/chip/进度条/图表/选中 tab。
4. **数字排版层级弱**:Pulse 组卡 CPU% 用 `.title3`,无 Vitals 式圆体大数字 + 单位小字 + 三列小统计的层次。
5. **无 avg/peak**:Vitals 卡上有 Average Today/Peak(load);Pulse 只有当轮值——**内存环形缓冲即可补**,这正是"现在便宜能做"的典型。
6. **无内存构成视图**:by Type(App/Wired/Compressed/Cached/Free)与 by App 环形卡 Pulse 均无。
7. **无状态徽章/异常区**:Vitals 有 `✓ Normal` chip、`Worth a Look` 面板、projects idle chip;Pulse 无任何状态语言。
8. **头部无环境信息**:Vitals 报 `Apple M1 Max · 10 cores · 64 GB` + `Up 6d 4h`;Pulse 头部只有一行系统 CPU 负载。
9. **排行无 meter**:Pulse 组卡/进程表是纯文字数值;Vitals 排行行内附占比条。

### 4.2 已排期(不是差距,按 tech-design §10 的节奏做,别顺手插队)

- 30 天历史、Today/Last 7 Days 累计卷:**P1 SQLite**(tech-design §5)。图表的"近窗口"版不在此列(见 4.3-1)。
- 磁盘卡 / 网络卡(系统总量)/ 电池卡 / Memory by Type:**P1**(公开 API);告警引擎 / Worth a Look:**P1**(§6);Projects tab(dev server finder):**P1**(§8)。
- GPU / Neural / 温度风扇 / Sound / Bluetooth / 容器 tab:**P2**(IOReport / SMC / CoreAudio / IOBluetooth / docker.sock,均免 root)。
- 每 App 能耗与 GPU(root helper)、MCP server、Agents 用量卡:**P3**。
- 多语言、license 体系:不做(自用)——这是仅剩的两处有意砍掉。

### 4.3 现在就便宜能做(不需要 P1)

1. **内存环形缓冲走势**(每指标/每组留最近 ~60 个采样,5s 节奏 = 5 分钟窗口):纯内存数组,`DashboardView`/`SystemMonitor` 各加一个环形缓冲即可画 strip。
2. **avg/peak 统计对**:环形缓冲上折叠,`Average Today` 可先做"会话内平均"。
3. **指标强调色表**:照 §1.1 表建双套 Asset/Color(light:dark:),先用于组卡图标、孤儿之外的类别色。
4. **tab 化布局**:弹窗顶部图标 tab(哪怕先 2-3 个 tab:组 / CPU / 内存),主窗口药丸 tab。
5. **figure 数字样式**:`.fontDesign(.rounded).fontWeight(.bold).monospacedDigit()` + 单位小字基线对齐,一行样式换掉 `.title3`。
6. **排行 meter 条**:组卡/进程行内加 6px 占比条(数据已有,按榜首归一)。
7. **chip 语言**:阈值判断(如组 CPU%>100% 挂 `高负载` chip)。
8. **头部环境信息**:`ProcessInfo.processInfo`(物理内存、host 名称、 uptime API)。
9. **Memory by App 环形**:drilldown 已有每进程内存,聚合 top5 即可(不需要新采样)。

需要**新采样字段但仍是实时数据**(介于两者之间,归入"不便宜"):内存 by Type 需 `host_statistics64`/`vm_stat64`(mach 实时 API,无历史依赖,但要动 Sampler);Swap 同源。

---

## 5. SwiftUI 落地映射

| 差距 | 组件/做法 | 数据需求 | 今天可做? |
|---|---|---|---|
| strip 微柱图 | 自绘最省:`HStack`/`Canvas` of `Capsule`(上圆角),高度=归一值;或 Swift Charts `BarMark`(隐藏轴)。轨道 `tint.opacity(0.09)` | 每指标环形缓冲(内存,~60 点) | ✅ 无需 P1 |
| 面积折线图 | Swift Charts `LineMark` + `AreaMark`(Gradient tint 32%→0),`.chartXAxis(.hidden)/.chartYAxis(.hidden)`,加 `RuleMark`×4 或 `LineMark` 网格;macOS 26 部署目标(`Pulse.xcodeproj/project.pbxproj:417`)全量可用 | 同上 | ✅(近窗口) |
| 每指标 tint | `Color(light:dark:)` 或 Asset 双套;按 §1.1 表;tint 派生用 `.opacity(0.09~0.16)` 对应 color-mix 9-16% | 无 | ✅ |
| tab 化 | 弹窗:`HStack` 图标钮 + 选中 `background(tint.opacity(0.15), in: Capsule())`;主窗口:同款带文字药丸 tab(Picker(segmented) 定制皮肤亦可) | 无 | ✅ |
| figure 大数字 | `.font(.system(size: 34).weight(.bold).design(.rounded)).monospacedDigit().kerning(-0.7)` + `HStack(alignment: .firstTextBaseline)` 放单位小字 | 无 | ✅ |
| meter 条 | `Capsule().frame(height:6)` 轨道 `tint.opacity(0.14)` + `Capsule().frame(width: w*ratio)` 填充,`.animation(.timingCurve(0.2,0.7,0.2,1,duration:0.6), value: ratio)` | 组/进程 CPU%/内存(已有) | ✅ |
| avg/peak | 环形缓冲 reduce min/max/avg;主卡两行 `Average/Peak` | 环形缓冲 | ✅ |
| donut(构成/排行) | Swift Charts `SectorMark`(macOS 15+);单色梯度:`tint` 每 segment 调 `opacity`/混 card 色 | by App:drilldown(已有);by Type:`host_statistics64` 新采样字段 | by App ✅ / by Type ⚠️(实时新字段,非 P1) |
| 状态 chip | `Text`+图标 in `Capsule().background(tint.opacity(0.14))`;阈值规则先本地写死 | 已有采样 | ✅(简化版) |
| 头部环境信息 | `ProcessInfo.physicalMemory`、`ProcessInfo.processInfo.systemUptime`、`host_info` 核数 | 系统 API | ✅ |
| 弹窗双布局(宽=卡网格/窄=紧凑行) | `GeometryReader` 断点或维持 340pt 紧凑行(与现状同构,补微条+强调色即可) | 环形缓冲 | ✅ |
| Worth a Look / 告警卡 | P1 AlertEngine(§6);UI 壳可先用简化阈值卡占位 | 阈值规则 | ❌(P1) |
| Today/7d 累计、30 天图 | SQLite rollup(§5)| P1 历史 | ❌(P1) |
| Projects tab(dev server)| argv/端口枚举 + idle 判定(§8)| P1 | ❌(P1) |
| Sound/Bluetooth tab | Sound:CoreAudio 音量/输入电平/每 App 音量;Bluetooth:IOBluetooth 外设电量(§10 P2) | 采样新增 | 📅 P2 |

---

## 附:证据清单

- CSS token:`vitalsmac.com/_astro/_guide_.CnFNrVbF.css`(`:root` / `@media(prefers-color-scheme:dark){:root:not([data-theme=light])}` 两块,本次 curl 下载核对)。
- 组件规则(`.card/.tab/.meter/.chip/.badge/.strip/.chart/.figure/.tnum/.panel`):同上 + `index.GL3ufeHm.css` + 首页内联 `<style>`(已提取核对)。
- demo 渲染参数(44 柱 / 56 点 / 2s tick / 归一化 meter):`/_astro/index.astro_astro_type_script_index_0_lang.DhGj8kWV.js`(本次 curl 下载,逐行读过)。
- 11 tab 的 DOM:首页 `id="pane-overview|cpu|memory|disk|network|gpu|neural|battery|sound|bluetooth|projects"`(已整块提取,每块首行标注)。
- 截图:OG(左大右小两弹窗)、SHOT1(主窗口浅色 8 tab + 6 卡 + Worth a Look + Right Now)、SHOT2(暗色 Sound 每应用音量)。
- og 图探测:除 `/og/home.png` 外 `/og/{cpu,memory,disk,network,gpu,projects,overview,main,dark}.png` 全部 404(本次 curl 逐个探测);`/love/shots/` 仅 2 张,与本地 SHOT1/SHOT2 字节数一致。
- Pulse 侧:`Pulse/DashboardView.swift`、`Pulse/MainWindowView.swift`、`Pulse/ProcessTableOrder.swift`、`Pulse/SystemMonitor.swift`、`Pulse/GroupingEngine.swift`、`GLOSSARY.md`、`docs/vitals-clone-tech-design.md` §1/§11、`Pulse.xcodeproj/project.pbxproj`(部署目标 26.0)。
- 未做/不可用:`mcp__4_5v__analyze_image` 视觉模型不可用;三张截图为本次会话用 Read 自行目视解读(未跑视觉模型)。
