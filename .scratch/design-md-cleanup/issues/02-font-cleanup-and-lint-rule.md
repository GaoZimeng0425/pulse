# 02: 字号收口 + lint 规则

**What to build:** 剩下 6 处旧的系统 10pt 小字改到 10.5pt,全 app 文字字号回到
五档;加一条 lint 规则,以后视图里再写系统语义字体,提交时就被拦住。

**Blocked by:** 01(同一个文件先后改:主窗口进程表的排序箭头与表头字号)。

**Status:** ready-for-agent

## Agent Brief

**Category:** enhancement

**Summary:** 6 处系统小字号改显式 10.5pt;SwiftLint 禁视图里的系统语义字体。

**Current behavior:**

进程下钻视图 3 处、主窗口进程表表头 1 处、清理设置页 2 处仍用系统 `.caption`
(10pt)。进程下钻里一处图标用 `.caption2`,一个预览块里也有一处 `.caption`。
没有机器检查,靠人记——上一轮清字号时漏了清理设置页 2 处。

**Desired behavior:**

- 这 6 处文字改为显式 10.5pt,字重保持不变(沿用既定的「10 → 10.5」对照)。
- 图标那一处与预览块那一处一并改为显式字号,规则不做任何豁免。
- SwiftLint 自定义规则:视图代码里出现系统语义字体(`.caption`、`.caption2`、
  `.footnote`、`.title3`、`.headline`、`.subheadline`、`.title`、`.title2`、
  `.body`、`.callout`、`.largeTitle` 作为字体使用)即报 error。注释、字符串、
  同名的数据属性(如模型里叫 caption 的字段)不得误报。菜单栏徽标本就用显式字号
  常量,不需要豁免。

**Key interfaces:**

- lint 配置新增一条自定义规则(先例:「删除闸」规则)。

**Acceptance criteria:**

- [ ] 全仓 lint 通过
- [ ] 规则确实生效:临时在视图里加一处 `.font(.caption)`,lint 报 error;撤掉后
      通过(自测过程记在票面 Comments)
- [ ] 语法结构查询核对:视图生产代码里系统语义字体零命中,注释与数据属性不被
      误报
- [ ] 进程下钻与清理设置页观感只差半号

**Out of scope:**

- 页面规格重写(票 04–06)
- 图标档位本身(票 01)

## Comments

- 2026-11-23 立票即分诊:冗余搜查无同题票;`.out-of-scope/` 知识库为空;分类
  enhancement;Agent Brief 已附。
