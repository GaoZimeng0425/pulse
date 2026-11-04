# 08: 开发者垃圾页 UI 重设计(用户实报不清晰;原型裁决 A,2026-11-04)

**What to build:** 原型存档 `prototype/junk-ui`(ab6f085)。用户三痛点 + 增量:组头全选 checkbox 突兀;整页黄(「先检查」warning 与磁盘金 accent 是 DESIGN 令牌别名,全页撞色);项目产物同名 node_modules 无法区分;工具缓存也要排序。定案:

1. **组头**:NSButton 三态 checkbox → 「全选安全项」文字按钮(语义钉死:只勾「可安全清理」且不在用项;先检查/在用永不进组选)。
2. **色彩纪律**:组名/行图标 tile/MeterBar 全中性灰;金只留 tab 选中与页脚主 CTA;「先检查」chip 换**琥珀橙**(新令牌 state-caution,DESIGN.md 先补表),「可安全清理」绿不变。
3. **项目产物按项目分子组**:项目行(名/项数/总量/N 久未动;子组勾选=该项目全部安全产物)+ 缩进产物行(产物名 + 一句人话 rationale 常显);JunkCandidate.projectName 已有(05 票埋好)。
4. **排序**:两组各配「大小|新旧」seg(工具缓存排序为本票新增需求);「新旧」口径——项目产物用项目年龄(newestChangeEpoch,05 语义),**全局缓存项补带节点最近变动 epoch**(语义注记:目录内任何文件最近变动,排序用)。
5. **页脚常驻**:「已选 N 项 · X GB」+ 主按钮「移入废纸篓…」(不再回页头找)。
6. 在用行压暗 + 灰 chip 维持。

**Status:** done

- [x] DESIGN.md 补 state-caution 令牌(琥珀橙,先检查档位专用)再动码
- [x] 夹具测试:全局缓存候选带 epoch;两组新旧排序(nil 排最后)
- [x] 夹具测试:项目分组(项目名聚合/项数/总量/最近活动聚合;无 projectName 的组不分组)
- [x] 「全选安全项」语义回归(只勾 safe 非在用)
- [x] 防漂移:两组排序 seg + 页脚在册
- [x] 真机目验归 07 收口清单(并入)

## Comments

- 2026-11-04 实施落地并合 develop(hook 装机):1072 例全绿(/tmp 复跑,用户发起)。
- 增补(用户实报,随本票落地):列表区独立 ScrollView 限高,「已选 N 项 + 清理…」
  合计条钉卡片底常驻(既有 actionBar 承担,新加重复 footer 已删)。实施坑两组:
  ①区间删除误吞 isBusy/actionBar 定义(git 恢复);②groups 单表达式过深触发
  type-check 超时,拆 groupsBody。DESIGN.md state-caution 先补表后写码。
- 目验项(组选按钮/琥珀档位色/项目子组/双组排序/合计条常驻)归 07 收口清单。
