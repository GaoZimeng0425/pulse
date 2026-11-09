# 01: app 侧——IPC 监听 + 安全档清单 + 清理请求桥接确认单

**What to build:** spec §架构 app 部分。

1. PulseCore 纯逻辑(`McpCleanSupport.swift`,双端共用,可测):
   - 端点文件 DTO(`McpCleanEndpoint`:port/token/pid,Codable)+ 0600 读写助手;
   - 路径求交:请求路径 ×(安全档 ∩ 非在用 ∩ 未排除)→ matched 候选 + 未识别路径(输入候选与活动条目,复用 `CleanInUse`);
   - HTTP DTO(请求/响应 Codable)+ 中文 prose 格式化(list_cleanable / clean 两工具的输出文案,单出口)。
2. app 侧 `CleanIPCService`(Network 框架,127.0.0.1 动态端口,token 校验,极简 HTTP/1.1 JSON):`GET /cleanable`、`POST /clean`;生命周期随 app,退出删端点文件。
3. `McpCleanBridge`(@MainActor 常驻):影子 `CleanerModel`(同装配,restoreCache-only)供关窗时列清单;真清理:窗口模型在→直连,不在→`openMainWindowNotification`(tab=cleaner)+ `NSApp.activate`,窗口 onAppear 落点消费;**替换**勾选为请求集 → `requestClean()` → 等确认(`withObservationTracking` 重挂观察 cleanPhase);10 分钟超时 `cancelClean()`;终态映射:finished=逐项结果、idle=用户取消、超时=撤单。
4. MainWindowView 装配:onAppear attach / onDisappear detach(仅接线,无视觉改动,DESIGN.md 不涉及新令牌)。
5. 测试:PulseCore 求交/格式化;PulseTests 桥接(假执行器:确认执行/取消/超时/未识别/busy 拒绝)。

**Status:** done(2026-11-09,分支 feat/mcp-clean;/tmp detach worktree 全量 check 绿 1175/1175——本 worktree 宿主测试两挂,已知 Documents 间歇问题;另:/tmp 验证时锚错 develop 跑过一轮白跑,教训=detach 必须锚提交号不能写 HEAD)

## Comments

**2026-11-09 实施记录:**

- **PulseCore 共用层** `McpCleanSupport.swift`:端点文件(0600 原子写)、
  `/cleanable`、`/clean` 的 DTO、求交 `McpCleanMatching`(安全档 ∩ 非在用,
  保护路径口径提公共 `CleanInUse.protectionPath(for:)`,界面组选同步改用)、
  中文文案 `McpCleanText` 单出处。8 例夹具测试(含端点权限、先检查/在用/未知
  原样退回、项目根活动保护、文案档位)。
- **桥** `McpCleanBridge`(@MainActor):影子模型同装配 restoreCache-only;
  列清单优先窗口活模型;submit 六步 = 找模型(冷开窗走告警深链 activate 三合一,
  等挂接)→ busy 拦截 → 求交 → **替换**勾选 `applyExternalSelection` →
  requestClean → 轮询终态(finished/idle/窗口被关三态,超时撤单只撤
  confirming,不打断 running)。单飞闸:同一时刻一个 clean。
- **IPC** `CleanIPCService`:NWListener 仅回环动态端口 + SecRandom 令牌,
  端点文件 `~/.Pulse/mcp-clean.json`;极简 HTTP 解析是纯函数(单测直喂字节,
  不碰 socket);连接 I/O 全收敛专属队列,跨界捕获 `nonisolated(unsafe)`
  显式标注(NWConnection 非 Sendable,队列纪律保证实际安全);退出删端点文件。
- **装配**:PulseApp 建桥(影子模型与主窗口同装配同源)+ 拉起 IPC;
  MainWindowGate/MainWindowView 纯接线(onAppear attach / onDisappear detach,
  无视觉改动,DESIGN.md 无新令牌)。

