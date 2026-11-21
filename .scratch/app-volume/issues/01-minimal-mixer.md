# 01: 每应用音量——外设页最小混音器(tap 引擎移植)

**What to build:** 外设页声音卡下新增「每应用音量」卡:正在出声的应用列表
(含系统提示音单行),每行 = 应用图标 + 名称 + 音量滑块(0–100%)+ 静音按钮;
音量/静音重启记忆。机制 = CoreAudio 公开进程 tap(macOS 14.2+,本机 26 全覆盖):
每 app 一个私有 tap(`mutedWhenTapped`,读即掐原声、停读自动恢复)+ 私有聚合
设备增益重播,不装驱动、不抢默认输出设备,别的 app 声音不经过我们。音频引擎
直搬 [Mixbar](https://github.com/lishuangqiang/mixbar)(MIT;链条 Fader +
MacMixer 均 MIT),核心 ≈540 行(`ProcessTap.swift` 263 / `CoreAudioSupport.swift`
254 / `VolumeCurve.swift` 26),THIRD_PARTY_NOTICES 随行。

**背景:** 用户 2026-11-21 发起"不同应用设置不同音量"。接口与参考已核实
(记忆 process-tap-per-app-volume):公开头 `AudioHardwareTapping.h` /
`CATapDescription.h`,`AudioHardwareCreateProcessTap` 14.2+,macOS 26 新增按
bundleID 挂 tap + `processRestoreEnabled` 自动重挂(本期不用,按进程对象挂)。
**本票推翻 P2 旧拍板**("声音纯展示层,不做控制交互、不做每 App 层",
`SoundModel.swift` 头注 + p2-sensors/05)——SoundModel 该句注释随本票顺带改掉。

**继承的 Mixbar 关键设计**(踩坑换来的,不重新发明):

- **音量 100% 不接管**:增益为 1 的 app 走原始路由,零成本零管线;用户从未
  调过音量就**不触发**系统音频捕获授权弹窗。
- 停读自动恢复(系统机制):Pulse 崩溃/退出,被控 app 声音自动回原路由,
  最坏情况是"控制失效"而非"没声音"。
- 自愈看门狗:渲染计数停 1.6s → 重建聚合管线,20s 内限 3 次,仍失败 → 放弃
  接管该行报错(原声自回)。
- 渲染线程纪律:无分配、无锁等待(os_unfair_lock trylock)、25ms 增益斜坡、
  >100% 峰值限制器(本期 UI 不开 0–200%,引擎保留)。
- 蓝牙 HFP 单声道下混、duplex 设备输入缓冲偏移、多出的输出声道置零。
- 滑块平方感知曲线(50% ≈ −12dB),100% 以上线性。
- systemsoundserverd 归一行「系统提示音」——macOS 所有通知提示音的总滑块。
- 归因:NSWorkspace 常规 app 匹配(bundle 前缀兜底)+ 可选 dlsym SPI
  `responsibility_get_pid_responsible_for_pid`(浏览器 helper,动态解析、
  缺失即退回;不上架 App Store 无审核顾虑)。

**分层与文件**(PulseCore 纯逻辑 / Live 引擎 / Feature / View 惯例):

- PulseCore `AppVolumeModel.swift`:滑块↔增益曲线、存储载荷编解码
  ({appKey: volume} + mutes,坏数据防御)、枚举快照×已存设置→展示条目归并
  (纯函数,单测)。HAL 枚举/管线全在 app target(头文件 ObjC-only,
  PulseCore 进不了)。
- Live `AppAudioPipeline.swift`(Mixbar ProcessTap.swift 移植,MIT 头注)+
  `AppAudioEnumeration.swift`(HAL 客户端枚举 + 归因 + 快照读取,≈12ms 移出
  主线程)。
- Feature `AppVolumeFeature.swift`(@Observable @MainActor):条目/设置/
  管线生命周期(建/拆/增益,reconcile 移植含 build token 防抖)、看门狗、
  睡眠销毁/唤醒重建、失败行重试;**枚举轮询 1.5s 走可见性闸**(蓝牙可见扫描
  同款 shows 家族,外设页可见才轮询,ADR-0006)。
- Feature `AppVolumeSettingsStore.swift`:AlertSettingsStore 模式 UserDefaults
  注入闭包,键名即契约。
- View `AppVolumeCardView.swift`:CardEntityRow 行(app 图标+名称+副文)+ 滑块
  + 静音按钮;**先补 DESIGN.md §Components 滑块行形态(宽走
  RowMetrics.meterWidth 两档)再造**,空态 = "等待应用播放声音"。
- `MonitorAssembly.swift` + `InertSources.swift` 双装配(Live 引擎 / Inert 桩)。
- `project.yml`:`INFOPLIST_KEY_NSAudioCaptureUsageDescription`(首次拖滑块
  才弹一次系统音频捕获授权;拒绝 → 该行错误文案 + 重试,绝不静默假装生效)。
- 根目录 `THIRD_PARTY_NOTICES.md`:Mixbar/Fader/MacMixer MIT 全文(参考提交号
  见其原文件)。加文件后 `xcodegen generate`。

**Status:** done(2026-11-21,develop@f464f13;Release 已装机重启,目验归用户)

- [x] PulseCore 纯逻辑 + 合成夹具单测(曲线/编解码/归并 13 例)
- [x] Live 引擎移植(Pipeline + 枚举),MIT 头注与 THIRD_PARTY_NOTICES.md
- [x] Feature + Store + 双装配 + 可见性闸(shows(.sound) 家族,外设页 1.5s 轮询;
      已接管管线不随可见性拆——窗口关着音量保持,每 tick 只补本地看门狗)
- [x] DESIGN.md 补滑块行形态 + CardEntityRow 真图标扩展 → 外设页卡片
- [x] project.yml NSAudioCaptureUsageDescription + xcodegen + `sh scripts/check.sh`
      (核心包全绿;app 侧 523 例唯一挂 LiveCoreTickSourceSmokeTests——单跑绿,
      高负载自扰老模式,与 agent-tab/01 同款零关联,记档合并)
- [x] 合 develop(f464f13;post-merge hook 已 Release 装机重启);编排回归
      9 例(AppVolumeFeatureTests:unity 不接管/建拆管线/失败重试/换设备重建/
      停摆看门狗/不可见不拆)

**Out of scope(后续候选):** 0–200% 增益 UI(引擎已留)、按输出设备各自记忆、
预设场景、全局热键、忽略列表、弹窗 compact 混音卡、输出设备选择器、浏览器
分标签归因、bundleID+processRestoreEnabled 重挂方式、DRM 内容(永不)。

## Comments

- **收批打磨(2026-11-22,@d2fa9a7/baa8df2,ub-mode 重读)**:①砍死码(曲线逆
  函数/管线 sampleRate/Inert gain/双重 tint);②`AppVolumeScan` 扁平化,clients
  不再双份搭乘,`AppVolumeSnapshot` 整体移除;③**图标归因跟宿主走**——浏览器
  helper 归并行此前拿 helper bundle 查图标会查错/查空,归因条目带上宿主
  appBundleID,新测试钉死;④测试轮询助手合一(PulseCoreTestSupport 共享
  waitUntil,存量 6 处异构私有助手评估不动)。行为不变:核心 13 例+编排 9 例
  +toast 6 例绿,全量 check 一次过。

- **测试边界(立票拍板)**:tap/聚合引擎**不进自动化测试**——hosted 宿主里
  建 tap 会触发 TCC 弹窗,高负载下有挂死前科(test-hang-cure 教训);引擎验
  证走装机目验。核心包纯逻辑照常单测。
- **异步时序教训(实现期)**:编排层的管线构建是 makePipeline(同步)→
  start(后台)→ finishBuild(回主线程)三段;测试 drain 必须等到**终态**
  (started/错误清除),等 makePipeline 那一刻会误判(token 还在途,重试
  被挡)。已按此修 AppVolumeFeatureTests。
- **验证指引(装机后)**:外设页 → 放歌(如音乐)→ 拖该行滑块音量变(首次弹
  授权点允许)→ 滑回 100% 松手回原始路由 → 静音按钮无声 → 退出 Pulse 所有
  app 声音自动恢复。
