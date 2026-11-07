# 07: 收口——稳态 / 防漂移盘点 / 目验清单

**What to build:** 二期卸载器 + 插队件结项。稳态与窗口指纹复测(卸载无常驻采集,应零增量;口径按 GLOSSARY 稳态词条)。防漂移测试最终盘点:子药丸注册(四门新序)、收据读取、残留位置规则、人话映射表、历史新去向登记完整性(p2-audit 教训)。真机目验清单交用户。全量 `sh scripts/check.sh` 绿(**由用户发起执行**,2026-11-04 纪律)。

**Blocked by:** 02, 03, 04, 05, 06

**Status:** done

- [x] 稳态复测数字记档(**免测结项**,2026-11-07 用户拍板;卸载器按 spec 无常驻
  采集——`loadIfNeeded` 挂子页 task、`onDisappear` cancel,稳态零增量的设计
  论证成立,但未实测,如后续怀疑回归再按 GLOSSARY 稳态口径补测)
- [x] 窗口指纹复测:卸载功能无常驻采集泄漏(**免测结项**,同上;观测法 =
  关窗后 `sample` 栈 grep 视图名,留档备查)
- [x] 目验清单(**免验结项**,2026-11-07 用户拍板;清单原文留在下框备查,
  未逐项点验):应用页排序 / 搜索 / 展开残留人话副标与全选、brew 徽标对拍、
  端到端卸载一个无价值 app(移废纸篓可恢复)、「彻底删除」文案与执行、
  失败如实报数、完成横幅与行移除、清空废纸篓闭环(磁盘数字下降)、
  地图「可清理」角标跳转、通知跳转、历史找回与类型标记、720 最小窗宽观感
- [x] 全量 check 绿;票组结项(2026-11-06 用户发起「跑」:lint+构建+1091 例全过,核心 643 + app 448,0 失败)

## Comments

- 2026-11-07 防漂移盘点(五项全有测试钉住,零缺口):
  ① 子药丸四门新序 = `CleanerAppSubTabTests`(顺序 + apps 标题);
  ② 收据读取 = `CaskReceiptTests`(6 例);
  ③ 残留位置规则 = `AppLeftoversTests`(17 例);
  ④ 人话映射表 = 同上,L208-209 全站点 plainTitle/consequenceNote 非空断言;
  ⑤ 历史新去向登记 = `CleanRunTypeTests`(isUninstall 标记)+
  `AppUninstallRunnerTests.testHistoryRoundTripsPermanentRoutes`(三种去向
  落库读回等值)+ `CleanHistoryStoreTests`(recycled/failed 往返)。
- 2026-11-07 结项诚实口径:稳态/指纹复测与目验清单两项经用户拍板**免测/免验**
  结项(非完成);全量 check 为实测绿。票组(p4-uninstaller 01–07 + 一期插队件
  01–06/04)全部结项;**p4-cleaner/06(AI 模型分组 + 孤儿 worktrees)仍挂起**,
  未纳入本期。
