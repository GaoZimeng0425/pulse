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

**Status:** needs-triage(非本分支引入,不阻塞 mcp-eyes 合并——单跑绿 + 三见均在满载整包轮)
