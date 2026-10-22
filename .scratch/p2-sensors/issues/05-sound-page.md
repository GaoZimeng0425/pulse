# 05: 声音区 + 创建外设页(最薄票)

**What to build:** 声音家族按降级口径打穿(非重点,纯展示):Live 适配器经 CoreAudio 属性变更通知**事件驱动**(零轮询),核心包纯值模型映射默认输出设备名、系统音量、静音状态;主窗口新开外设 tab(本票创建,蓝牙区留给 06),先放声音区;弹窗声音紧凑组(设备名+音量)。不做任何控制交互,不做每 App 层(已出范围)。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] 外设 tab 上线,声音区显示默认设备/音量/静音,插拔耳机即时反映(事件驱动,无轮询)
- [x] 弹窗声音紧凑组出现
- [x] 属性→展示值映射合成单测;无设备/读失败的空态不崩
- [x] 关两窗指纹全零;check.sh 全绿(699 例:核心 371 + app 328)

## Comments

**执行记录(2026-10-22 晚)**:
- 核心包 `SoundModel`:SoundRawReading(设备名/音量标量/静音位原始载荷)→
  SoundReading(标量×100 钳 0…100,nil 穿透不伪造 0%)。5 例单测。
- Live `SoundSensor`:LiveSoundSource(默认输出设备 + 设备名 + 主声道音量/静音,
  主声道缺席按声道 1/2 顺读)+ CoreAudioWakeupStream(系统对象盯默认设备切换、
  当前设备盯音量/静音,默认设备切换时换挂监听;构造即首唤醒——IOPSWakeupStream
  同款形状)+ SoundSensorProvider(`.onEvent` 档,无可见性闸:事件稀少便宜,
  关两窗零成本)。4 例测试(节奏档/lastGood/事件流形状/Live 冒烟)。
- 外设 tab = MetricTab 第 10 轴(传感器后磁盘前),标题"外设"、符号 headphones、
  强调色取 Bluetooth 青;Metric 新增 sound/bluetooth 两行令牌(色值 = Vitals
  参考文档 §1.1 现成行,零发明色)。MonitorVisibility 加 peripheralsPage 旗标
  (声音不消费;06 蓝牙扫描闸消费)。
- 顺手修:SystemMonitor 可见性 setter 全参重建在 setMainWindowVisible 漏传
  sensorsPage 把旗标清零(04 引入的隐性 bug)——五处一并收敛为拷贝-改写式。

**待用户目验**:
- 外设 tab 声音卡:设备名/音量条/静音图标与系统实际一致(对照控制中心)。
- 插拔耳机或改音量,卡面即时跟随(事件驱动,无轮询延迟)。
- 弹窗(外设 tab 紧凑档)同形状。
