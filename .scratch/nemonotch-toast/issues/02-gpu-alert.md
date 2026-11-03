# 02: GPU 利用率告警(第五类进 toast 的规则)

**What to build:** AlertKind.gpuUtilization——GPU >90% 持续 5 分钟告警;数据吃 30s 历史档 gauges 广播(`gpu_util` 键,缺席轮不喂不伪造 0),零新增稳态成本;路由 GPU 页;toast 无进程归因(macOS 不给每 App GPU,P3 探针实证本机列不可读,不硬造)。

**Status:** done(2026-11-03,develop@f83eaee;用户拍板 A 于同日)

- [x] 引擎:预设 90%/300s/600s,系统级主体 `gpu`;`AlertFeed.gpu` 喂食
- [x] 接线:AlertCenter.onEvent(.gauges) 提取 gpu_util;AlertRoute.gpu → GPU 页
- [x] toast:「GPU 利用率过高 97%」,正文引导 GPU 页;系统通知同构文案
- [x] 设置页百分比阈值行 + 副标题(说明不带进程名)
- [x] 测试:引擎持续窗用例 + 文案用例 + gauges 接线用例;全量 993(+1 全量负载噪音单跑绿,AcceptanceAnchor 同款)

## Comments

- **拍板(2026-11-03)**:选 A(GPU 利用率规则);B(温度规则)不做——温度归因更弱且 M4 阈值难定。
- **回落拍板(2026-11-03)**:**不加**失败回落(用户明示「NemoNotch 常开」为约定)。代价当天即现:NemoNotch 停机期间 16:45 系统负载真告警的卡未送达且不补发(触发态不重发);已如实告知,用户接受该语义。
- **流程事故记档**:本轮合并时 post-merge hook 半途死(14:05 杀 Pulse 后未装机),手动 `sh scripts/build.sh` 补上;原因未查,再发即立票。
