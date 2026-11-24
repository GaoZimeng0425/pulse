# 03: MCP 清理事务契约收口——超时闭合、连接取消、协议版本

**What to build:** 修复 REPORT 中6/中12:客户端 615s 先于服务端最坏 660s 放弃(客户端报失败而删除照常发生);本地 HTTP IPC 无逐连接读看门狗,连接取消不传业务;`@unchecked Sendable` 承诺与代码不符;协议无版本协商。

**Status:** ready-for-agent

证据见 `../REPORT.md` §中6、§中12。关键锚点:`McpCleanBridge.swift:38-41,106-120,149-182`;`pulse-mcp/main.swift:212,227,251`;`CleanIPCService.swift:11-31,59-84,97-104,113-137,158-168`;`McpCleanSupport.swift:12-21,55-141`。

**Agent Brief:**
1. 超时单一真源:把 `windowWaitSeconds + confirmTimeoutSeconds + buffer` 通过 `/health` 或端点文件下发,客户端据此设 `timeoutSeconds`;或至少抽 PulseCore 共享常量并断言客户端 > 服务端最坏值。大改前先确认取消语义:客户端超时后发带同一请求 ID 的取消请求,桥支持幂等撤单(当前 `cancelClean` 只在 `confirming` 生效且无请求标识)。
2. `CleanIPCService.receiveLoop` 加逐连接看门狗(建议 30s 收不齐完整请求即 cancel);连接 `.cancelled` 接到桥的取消路径;加并发连接上限。
3. `listener` 真正收进队列(actor 化或所有读写走 `queue.sync`),`stop()` 不再从 handler 线程直接写属性,deinit 只投递 shutdown;端点文件清理收敛到单一路径。
4. 端点文件与 `/health` 加 `protocolVersion`/`minCompatibleVersion`,不匹配返回明确"请重启 Pulse / AI 客户端"文案,替代 JSONDecoder 失败的含糊"查询失败"。
5. 测试用真实回环连接覆盖:半开连接被看门狗关掉、客户端断开 → 桥撤单、旧版本握手被拒。

**验收:** 不存在"客户端已失败、服务端仍删除";半开连接不能无限挂住;版本不兼容有明确报错。

## 核实(2026-11-24)

真但被夸大,降为低。超时错配只在冷开窗 + 用户恰在 ~600s 点确认时出现;删除仅限安全档且移废纸篓。半开连接只挂单连接、限本机;@unchecked 注释不准但无实际并发路径;协议版本是潜在问题。**Brief 收窄**:共享超时常量 + 断言(或客户端拉到 ~700s)、逐连接 30s 看门狗 + 连接上限、端点文件加 protocolVersion。不做请求 ID 撤单协议与 actor 化。
