# 05: 每日消耗卡重排(定稿原型)+ 模型 / harness 维度

**What to build:** 智能体页「每日消耗」卡按定稿 HTML 原型
(`.scratch/agent-tab/prototype-daily-usage.html`,唯一视觉真相,JS 坐标数学可直译)
整体重排,并给账本加**模型维度**。技术方案已拍板(2026-11-13):折线 = 官方
Swift Charts(首次引入)、热力墙 = 自封装小组件、分段条 = SwiftUI 原语。

**定稿设计决策(用户逐条拍板,不得偏离):**

1. 卡头无 icon:标题文字 + 右「重新扫描」(徽章删掉)。
2. 布局顺序:数字卡排(3 张同规格 lift 小卡)→「Token 消耗」(热力墙)→
   「走势」(满宽)→「项目」(大卡)。
3. 数字卡三张同规格:今日消耗(accent 色 + 环比副行)/ N 天合计(环比)/
   日均(峰值副行);同宽同字号(figure-stat 28)同三行结构;随 7/30 联动。
4. 每个图表区统一组件:lift 外包装 + 标题行(左标题、右时间筛选药丸)+ 下图表;
   热力墙无切换但右侧放单选项「年」占位(时间筛选位置恒定)。
5. 热力墙:正方格边 14、间距 4、52 列(一年)、外层恒满宽内容超宽横向滚动、
   底部每 8 周刻度(51周/43周/…/3周/今,JS 原式)+ 开卡滚到最右(今)。
6. 走势:xy 坐标轴——y 轴 token 三档(0/半值/峰值)+ 水平网格线、x 轴天刻度
   (7 天图每 3 天、30 天图每 6 天,「今天」在右);域顶留 15% 头寸;
   末点圆点;图区 6% accent 底。
7. 项目大卡(自适应网格 min 240 / max 340 / 列距 12):头(项目名 14.5 /
   占比)→ 主数值 figure-card 24 + 环比 → 模型分段条 + 色点图例 → harness
   分段条(claude/zcode)+ 底行(在跑 N 或静了 N)→ 活跃行(活跃 N/窗口 天 ·
   请求数)。单列时卡片满宽。
8. 模型 / harness 异色 = 分区异色映射既有令牌(DESIGN.md 新别名
   agent-model-lead/second/rest = accent-bluetooth/memory/disk;harness
   claude/zcode = 前两色)。
9. 模型最多 3 项:按占比取前二 + 剩余并「其他」。
10. 弹窗紧凑档(312pt)同布局自适应;数字卡值 minimumScaleFactor 兜底超宽读数。

**数据改造(模型维度):**
- Claude:jsonl 每条 assistant 行自带 `message.model`(实测 100% 带;
  `<synthetic>` 等原样入桶,占比小自然归「其他」);ZCode:`model_usage.model_id`
  列已存在(NOT NULL),SELECT 直接带出;列探测缺失降级 NULL(老 schema 不炸)。
- 新表 `agent_daily_model_usage`(day, source, project, model 主键,五桶对称),
  迁移 `agent-tab-05-model-usage` 照 HistoryDatabase 惯例;模型轨与项目轨同喂
  双写,cache 回填不进;重扫覆盖 upsert。
- 派生全部出现有数据:环比(今日 vs 昨日、窗口 vs 前窗口)、峰值、活跃天数、
  请求数(request_count)、harness 占比(= source 维度)、「在跑 N」
  (monitor.agentSessions.snapshot 会话行按项目名匹配,组装时传入;Claude 用
  cwd 全路径 worktree 归组,ZCode 补 workspaceRoot 字段同法)、「静了 N 天」
  (该 projectId 距最后活跃日的天数;0 = 今天活跃——日粒度账本派不出小时,原型
  「静了 2 时」的时粒度如实降为天)。
- 模型显示名剥 "claude/" 与 "claude-" 前缀(claude-opus-5-5 → opus-5-5)。

**测试纪律:** 夹具日期一律从 now 动态推导(硬编码 + 真实时钟跨午夜必挂);
enumerator 相对路径用父目录名拼(04 票实案)。

**Status:** done(2026-11-13,develop@73d68a2;装机目验归用户)

**Checklist:**

- [x] DESIGN.md:figure-stat 28 入 typography、agent-model-* 入 colors、
      Components 加「每日消耗卡 v2」节(原型 9/10/13/14px 非网格值收编表)+
      Apple Charts 登记例外补第二先例
- [x] PulseCore:样本带 model(ClaudeUsageSample.model / ZCodeUsageSample.modelId)、
      AgentModelUsageRow + 聚合器模型轨(项目+模型都归组成功才进)+ store、
      迁移 agent-tab-05-model-usage + tableNames
- [x] PulseCore:`AgentUsageWindow` 窗口派生纯函数(数字卡三卡数据 / 项目卡
      数据 / top3 模型合并 / 环比 / 在跑计数 / 逐天合计)+ ZCodeSessionStatus
      .workspaceRoot(zcodeRows 填充)
- [x] Live:SELECT 带 model_id(列探测缺失补 NULL 降级);Feature 暴露 modelRows
- [x] UI:整卡重排(CardHeader 徽章可选化 / AdaptiveCardGrid 加 maximumCardWidth
      (memberwise 默认参,调用面不动)/ 52 列热力墙横滚小组件(开卡锚「今」)/
      Charts 走势(y 三档网格 + x 每 3/6 天 + 末点圆点 + 15% 头寸)/ 项目大卡
      (分段条 SwiftUI 原语 + 色点图例 + 在跑/静了/活跃行))
- [x] 测试:模型轨三轨聚合/解析/store/全量接线、窗口派生 8 例(数字卡环比/
      项目全字段/top3/在跑 worktree 折叠/显示名)、读取器 model_id 两例、
      会话 workspaceRoot;夹具全动态日期
- [x] check:lint(ast-grep 两处 ForEach(indices) 违规已修)+ 构建 + 核心包 793 绿
      + app 侧大跑 506 绿;**AcceptanceAnchor e2e 在并行会话负载风暴
      (load 30-60)下忙循环饿死失败 3 次,同码单跑绿**(与票改动零关联,
      「负载风暴换着挂」协议);读取器夹具修后单跑 6/6 绿
- [x] code-review Standards 轴自查:防御(nil 穿透/无基准「—」/峰值 0 全灰/
      老列降级)、并发(纯值函数 + GRDB 串行 + IO 后台档,零新共享态)、
      权限(零新增 TCC 面)、测试(纯 XCTest/合成夹具)、注释(为什么+票号)过

**Comments(实案教训):**
- 并行会话风暴(load 30-60,syspolicyd 218% + 别的项目 du + log show 取证)
  能把忙循环测量型 e2e 饿出假失败——同码单跑绿 + 零代码关联才可放行,
  「单跑即绿」在风暴天要多次重试才能凑到安静调度窗口。
- SwiftFormat/lint 基线会重排新代码(6 文件),提交前 `lint.sh --fix` 一遍
  免得 check 阶段折返;ast-grep 门禁拦 ForEach(indices) 形状,聚合行值从
  enumerated 元组取(2026-10-21 删行闪退实案的规则)。
- 首版走势图想用「两张 Chart 叠末点」补丁,坐标对不齐——单 Chart 内
  LineMark 序列 + 条件 PointMark 才是正解(ForEach 同 series 连线)。

**Out of scope:** 热力墙年档切换(「年」是占位)、小时粒度闲置、单项目下钻、
模型维度单独时间筛选、MCP 暴露。
