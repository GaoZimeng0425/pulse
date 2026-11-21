# 01: AlertCenterToastTests.testBothOutletsDeliver 满载偶发双发

**现象(2026-11-09 起,两日内三见):** 全量 check 在机器满载(并行构建/多 worktree 连跑)时,`testBothOutletsDeliver` 挂:

```
AlertCenterToastTests.swift:207: XCTAssertEqual failed: ("2") is not equal to ("1")  // toast.sent.count
```

**已排除:**
- 与 mcp-clean / mcp-eyes 改动无关——2026-11-09 第一次挂发生在**纯 develop**(误锚 HEAD 的 /tmp 轮),彼时两分支都没进。
- 隔离跑恒绿:两日各单跑一次 `--only AlertCenterToastTests`,6/6 全过。
- 同一晚 mcp-clean 最终全量轮(载荷稍轻)整包 1175/1175 过。

**定性:** 载荷敏感的时序竞态——疑点在 `fireSystemLoad` 的三轮 onRound + Task.yield 与 toast 假发送器的竞程(满载下 yield 让渡不均,可能双触发投递路径)。未定谳,先挂账。

**修复方向(接手时):** 给 FakeToastSender 的计数路径加串行化或把 fire 收敛为确定性等待(await 到 toast.sent 变 1 再断言);不要用 sleep 重试糊。

**Status:** done(2026-11-22 定谳修复,feat/chore-debts 批)

## 定谳与修法(2026-11-22)

**真凶(非票面原疑点)**:不是 toast 路径——`setEnabled` 拉起的授权请求链
(`requestAuthorization → recordStatus`)在满载下**晚于告警触发落地**;此刻
`wasAuthorized=false→true` 的转变触发补发,而 `resendingExcept` 只排除**同批**
的 identifier,把批次**已经送达**的同一条告警再补一遍。测试里 = 双计数
(旧版行号是 toast 断言、新版是 system 断言,当年行号漂移误导了方向);
生产里 = 同一告警**双横幅**(窄竞态:授权请求在途时恰好有告警触发)。

**修法**:AlertCenter 记「本会话已送达 identifier 集合」——批次**决定发即
记账**(发完才记会留窗口,补发链读不到),补发过滤该集合,`.resolved` 即清
(同主体再触发是新 occurrence,照发);identifier 构造收单一出处
`AlertNotificationContent.identifier(kind:subjectKey:)`。授权后补发「从未
送达」的既有语义不受影响(AlertCenterTests 381-414 原测全绿)。

**回归钉死**:`testBothOutletsDeliver` 给假发送器注入 80ms 授权延迟,把满载
竞态变成**确定性复现**(修复前必红);等待改为确定性条件(授权链落地 + 批次
送达)而非固定 yield 数。
