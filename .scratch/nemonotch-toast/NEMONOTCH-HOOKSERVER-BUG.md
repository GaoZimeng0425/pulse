# NemoNotch HookServer:请求体完整性判定对「两段式发送」恒真

> 交付对象:NemoNotch 仓库的处理会话(2026-11-01 用户拍板 B:由 NemoNotch 侧自修)。
> 诊断全部在本机实测,Pulse 侧无需改动,等修复装机后按文末步骤联调即可。

## 症状(用户视角)

1. **外部 toast(`POST /v1/toast`)**:用 curl 发永远 200;**用 URLSession 的客户端第一发必 `400 {"reason":"Malformed JSON body"}`**。同一进程后续再发又能成功——「第一发挂、后面成」的间歇假象(机制见根因)。Pulse 的告警 toast 就卡在这里:告警准时触发、归因正确、载荷完全合约,被误拒。
2. **`/hook` 大事件被截断**:>64KB 的 PostToolUse 等事件解码失败,NemoNotch 日志 `Failed to decode HookEvent … "Unexpected end of file" — body 65312B/65313B`,体长恒 ≈65312 = `receive(maximumLength: 65536)` 首段减去头块。2026-11-01 17:57–17:59 三连实锤(另一个 ZCode 会话的 hook 事件被静默丢弃)。

## 复现(python 原始 socket,本机已验证)

对 `127.0.0.1:<hook-port>/v1/toast` 同一合法载荷:

| 发送方式 | 结果 |
|---|---|
| 单段(头+体一次 `sendall`)| 200 |
| 两段:头 ‖ 体 | **400** |
| 两段:头+5 字节体 ‖ 余体 | **400** |
| 两段:头+10 字节体 ‖ 余体 | **400** |

URLSession 在**新连接**上固定先写头、后写体(假服务端抓包:2 个 TCP ���,头 319B + 体 190B);连接复用后 CFNetwork 常把头体合写 → 单段 → 成功。curl 永远单段写 → 永远成功,所以 `external-toast-agent-guide.md` 的 curl 验收清单全过、bug 不可见。

## 根因:`NemoNotch/Services/HookServer.swift:266`

```swift
private nonisolated static func hasCompleteHTTPRequest(_ data: Data) -> Bool {
    guard let str = String(data: data, encoding: .utf8),
          let separator = str.range(of: "\r\n\r\n") else { return false }
    let headers = str[..<separator.lowerBound]
    let body = str[separator.upperBound...]
    if let clRange = headers.range(of: "Content-Length:", options: .caseInsensitive) {
        let after = headers[clRange.upperBound...]
        if let lineEnd = after.firstIndex(of: "\r") {        // ← 266 行:恒 nil
            let value = after[..<lineEnd].trimmingCharacters(in: .whitespaces)
            if let cl = Int(value) {
                return body.utf8.count >= cl
            }
        }
    }
    return true                                                // ← 于是每次都落到这里
}
```

Swift 把 `"\r\n"` 聚成**一个** `Character`(grapheme cluster),头块里不存在独立的 `"\r"` 字符 → `firstIndex(of: "\r")` 永远 nil → Content-Length 分支整体跳过 → 兜底 `return true` → **只要头块到齐就宣布请求完整**,体还在路上就拿空体 / 半体去解析:`/v1/toast` 得 `malformedJSON`,`/hook` 得 `Unexpected end of file`。

> 讽刺的是同文件 `headerToken`(约 521 行)的注释明确写着这个坑——「Swift 把 "\r\n" 视作单个 Character,不能用 `firstIndex(of: "\r")` 找行尾——必须按换行符集合切分」——那边躲了,这边没躲。

隔离验证(把函数原样抠出跑):头+空体 → **true**(应 false)、头+5 字节体 → **true**(应 false)。

## 修法(一行,已验证)

```swift
if let lineEnd = after.range(of: "\r\n")?.lowerBound {
```

或与 `headerToken` 同款 `after.components(separatedBy: .newlines).first`。修后隔离验证:头+空体 → false(继续收)、头+5 字节体 → false、头+全体 → true。

顺带建议:整个文件 grep `firstIndex(of: "\r")` / `"\n"`,只剩 266 这一处;`String(data:encoding:)` 在多字节字符被 TCP 切半时返回 nil → 走 `return false` 继续收,这条路是对的,不用动。

## 回归测试建议

`hasCompleteHTTPRequest` 已是 `static`,提成 `internal`(或 `@testable` 可见)后直接钉:

- 头块 + Content-Length>0 + 空体 → `false`
- 头块 + 部分体 → `false`
- 头块 + 全体 → `true`
- 无 Content-Length(GET /health)→ `true`
- 体含多字节字符、恰好切在字符中间(`String(data:)` 为 nil)→ `false`

落点:现成的 `HookServerRouteTests` 族,或新开 `HookServerFramingTests`。再补一条 socket 级两段式用例(NWConnection 或 python 探针脚本入仓)更稳。

## 修好后受益面

- `/v1/toast` 对**所有** URLSession 客户端可用(Pulse 已接入,契约字段全对)
- `/hook` >64KB 事件不再被截断丢弃(另一会话正在遭此损失)
- `docs/external-toast-agent-guide.md` 验收清单建议补一条「非 curl 客户端(URLSession/NSURLSession)」用例——curl 的单段发送掩盖了此 bug

## 修复装机后的联调(Pulse 侧已就绪,零改动)

Pulse develop(≥ `7c36be0`)已带完整集成:系统负载 / 组 CPU / 新组内存 / 磁盘不足四类告警触发即推 toast,标题点名承载组、正文列前三名进程及 CPU%/内存。验证:

1. Pulse 设置 → 告警 → 「系统负载」阈值临时改 **5**(环境负载必越阈;持续窗 5 分钟 + 3 轮);
2. 约 6 分钟后刘海下出现「系统负载过高:<组名>」卡,正文「最耗 CPU:xxx NN%、…」,点卡激活 Pulse;
3. `~/.Pulse/logs` 最新日志应见 `告警触发:系统负载`,**不再**出现 `NemoNotch toast 被拒(HTTP 400 …)`(Pulse 已把 reason 写进日志);
4. 阈值改回 70。

快速契约自测(不等告警):`sh` 里按指南第 6 节 curl 一次仍应 200;再用任意 URLSession 客户端(如 `swift` 一行脚本 POST)首发也应 200——这是修复的判据。
