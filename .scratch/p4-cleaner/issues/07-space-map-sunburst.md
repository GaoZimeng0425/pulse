# 07: 空间地图——两环旭日图(只读:下钻 / 面包屑 / 悬浮)

**What to build:** 旭日几何做成纯值计算(空间树 → 弧段:角度 / 两环 / 标签可读性规则),视图薄。SwiftUI 视图:两环旭日、点块下钻、面包屑逐级可点返回、悬浮提示(路径 + 实际占用大小 + 占整卷百分比)、系统密封区折叠为单块不透明不可下钻(点击有解释)、中心显示当前根与「返回上级」、v1 只读 +「在 Finder 中显示」、口径注记;地图与开发者垃圾子页读同一次扫描结果(03 的缓存)。形态以原型 B 变体为准(分支 prototype/cleaner-ui);DESIGN.md 纪律:无投影、配色用既有令牌体系、新色先入表。

**Blocked by:** 03(与 04-06 并行)

**Status:** done(2026-11-01,develop@2962ca7)

- [x] 下钻 / 返回正确;面包屑逐级可跳
- [x] 密封区块拒绝下钻且点击有解释;叶子节点无更深层如实反馈
- [x] 悬浮信息与树数据一致(占比 = 大小 / 整卷)
- [x] 几何纯值测试(弧角度 / 展开占比 / 标签阈值),视图薄壳
- [x] 只读:地图上没有任何删除入口(ADR-0008 的边界,UI 无删除控件)

## Comments

- **交付(2026-11-01)**:几何与树变换全在 `PulseCore/SpaceMap.swift`——
  ①**firmlink 提升**(关键探针:根目录原始枚举序 System 在 Users 之前,深度优先先在
  /System/Volumes/Data/* 抢占 (dev,ino),顶层 Users/Applications/private/opt 在扫描树里
  全被 double-visit 跳过——不提升的话 System 一块吃掉 ~90% 环宽);Data 直接子目录拼回
  顶层并规范化路径(/System/Volumes/Data/Users → /Users),System 余量(SSV + Preboot/VM/
  Update 卷)折叠为「系统(密封)」单块;/bin、/sbin 一并密封;/usr 不密封(含 /usr/local
  用户空间)。②弧几何:内环子辈 / 外环孙辈、叶子与密封块延伸占满外环、小份额尾部并入
  「其他」、满圆留缝钳制、悬浮占比分母 = 整卷树(≠环内归一化)。视图
  `CleanerSunburstView.swift` 薄壳:内环循环十个既有 accent 令牌 + 外环随父色(零新色,
  DESIGN.md 增 `{layout.sunburst-diameter}` 340 与空间地图卡组件行);下钻状态由
  CleanerTabView 持有(切子药丸不丢)。
- **测试**:核心 16 例(提升/密封/排序/零字节裁剪/比例连续/其他合并/满圆钳制/导航/
  标签翻转)+ app 1 例端到端(夹具树 → model.mapTrees 提升 + 密封);全量 921 例。
  LiveCoreTick 冒烟在全量套件下照旧抖动,**单跑绿**(dd4a1f1 同款,已记档非本票回归)。
- **顺手修(27141a5,阻门真 bug)**:磁盘容量对账在更新预置期间双计系统卷——disk3s1
  本体挂 /System/Volumes/Update/mnt1(Sealed: Broken)与 "/"(disk3s1s1 密封快照)同一份
  块,各卷之和恰多 19.17 GB、磁盘明细多一行 mnt1、LiveDiskSourceSmokeTests 红。
  `DiskCapacity.memberKey` 双层片设备归约到成员 + make 去重先到先得;夹具 +
  2 例单测。这台机器装的是 macOS 更新预置态,修完磁盘明细应不再有 mnt1 行。
- **欠目验(用户)**:起 app → 清理页 → 空间地图子药丸:①旭日两环 + 内环标签;
  ②点 Users 下钻、面包屑逐级跳回、中心「返回上级」;③悬浮提示(路径/大小/占整卷%);
  ④点灰色密封块 → 信息行解释(不下钻);⑤「在 Finder 中显示」真的开 Finder;
  ⑥磁盘页明细:不应再有 mnt1 行(顺手修的观感)。
