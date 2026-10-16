# Pulse

macOS 菜单栏系统监视器。以 [Vitals](https://vitalsmac.com) 为界面与数字口径基准的个人复刻,并在它没做深的方向上做深——**项目 / agent 会话级归因**:回答"到底是什么在占用我的 CPU",而不是给一千行进程列表。

> 2026-10-12 那次 load 52 的真相:octok-client 两个 worktree 同时跑质量门禁(cargo test + vitest --coverage)+ 一个常驻 App 白烧 60% + OrbStack VM 86%。活动监视器只会给你 1000 行进程列表;Pulse 把它归成三行,每行都能下钻到进程树、启动时间、cwd、完整 argv。

## 功能(P0 已完成)

- **菜单栏双读数**:CPU + 内存,内存按压力变色(偏高橙 / 紧张红)
- **三层归因引擎**:bundle 归属(含 Helper/XPC 子进程跟随)→ 父链上溯 + 出生登记(防中间进程死亡断链)→ 项目根匹配(cwd / argv,支持 worktree 显示为"项目名 @ worktree");孤儿进程橙色高亮——它往往正是问题所在
- **弹窗**:全部进程组滚动列表(不只 Top-5),组卡带走势微图、平均/峰值、状态徽章
- **主窗口**:总览指标卡(CPU user/system 拆分、内存构成)、当前最忙排行卡、可排序进程表、工具栏搜索(按应用名或进程 PID)
- **动作**:结束整组 / kill 进程树(确认后执行);项目根在设置里配置
- **资源预算**:全程用户态 API,无 root、零第三方依赖;合盖 5s / 开窗 1s 自适应采样

## 技术栈

- SwiftUI + `MenuBarExtra`,部署目标 macOS 26+
- 数据采集直调 Darwin API:`proc_listallpids` / `proc_pidinfo` / `host_processor_info` / `host_statistics64`
- 纯逻辑层与 OS 边界以 `ProcessSource` 协议分隔,229 个单元测试跑在合成进程树上

## 构建

```bash
xcodegen generate        # 工程由 project.yml 生成,勿手改 pbxproj
open Pulse.xcodeproj     # Xcode 里 Run
```

开发时建议装提交闸门(staged 含 Swift 即增量构建,失败拦截):

```bash
sh .githooks/install.sh
sh scripts/check.sh      # 全量检查:构建 + 全部测试
```

## Roadmap

按"权限门槛"分阶段,免 root 的先做(逐传感器 API 选型见 `docs/vitals-clone-tech-design.md`):

- **P1**:SQLite 30 天历史 + 告警引擎 + dev server finder + 磁盘/网络/电池卡(APFS 容器级容量口径)+ 项目可回收产物扫描
- **P2**:GPU / 神经网络引擎 / 温度风扇 / 声音 / 蓝牙 / 容器卡——全部免 root
- **P3**:root helper(每 App 能耗/GPU/网络归因)+ MCP server(供 AI 直接询问 `why_cpu_high()`)

## 参考与致谢

- **UI 形态与数字口径基准**:[Vitals](https://vitalsmac.com)(闭源,仅做行为对齐,未接触其代码)
- **算法参考(MIT,移植处已在文件头注明)**:[exelban/stats](https://github.com/exelban/stats)(GPU/ANE/SMC/网络/电池)、[henrydennis/petal](https://github.com/henrydennis/petal)(APFS 容器级容量)、[jithin-sabu/purge-app](https://github.com/jithin-sabu/purge-app)(项目产物目录学与活跃度判定)
- **点子参考**:[tw93/Mole](https://github.com/tw93/Mole)(GPL-3.0,仅取思路,未使用其任何代码)
