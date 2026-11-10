# p6-cleaner/02:AI 模型域(存储位 + 内容寻址真实可回收 + 在用第四路)

Status: ready-for-agent
Blocked by: 01

## 目标

复活 p4-cleaner/06:`aiModels` 组四条规则 + Ollama 内容寻址真实可回收量 + 在用保护第四路(服务进程)。

## 范围

1. 四条规则全「先检查」:`~/.ollama/models`、`~/.lmstudio/models`、`~/.cache/huggingface`、GPT4All 常用位(`~/Library/Application Support/GPT4All`);不在场不列、规则照登记。
2. Ollama 内容寻址(纯值进 PulseCore):`manifests/<registry>/<model>:<tag>` → layers blob 清单,按 digest 去重求和 = 真实可回收(共享层不重复计);大小口径仍走扫描树(blobs 是普通文件),manifest 解析只决定「哪些 blob 计入」。非 Ollama 存储位整目录口径。
3. 在用保护第四路:ollama 服务进程在跑(进程名 / argv 命中)→ AI 组候选在用灰行;接 `CleanActivitySource` 既有管线(判定不缓存、删除前重查照旧)。
4. 防线沿用:确认单 / 废纸篓 / 历史(ruleID `ai.ollama` 等)/ 右键排除;登记完整性正例。

## 验收

夹具:两模型共享一层 → 可回收 = 私有层之和 + 共享层只计一次;ollama 进程在场 → 灰行;manifest 缺失 / 损坏 → 整目录口径兜底并如实标注。

## Comments
