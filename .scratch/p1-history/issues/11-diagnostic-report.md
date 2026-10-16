# 11: 诊断报告复制

**What to build:** 设置里一键复制诊断报告(纯文本):app 版本/build、macOS 版本、机型芯片、采样统计(运行时长/采样轮数/平均耗时/进程数峰值)、最近日志尾部;日志从 LogService 目录读取(本地时间戳);复制成功有反馈。报 bug 时用户不用手拼信息。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] 报告含 spec 列明全部字段,纯文本可直接粘贴
- [ ] 日志尾部为本地时间戳、截取最近 N 行(避免巨型粘贴)
- [ ] 设置页入口 + 复制成功反馈;采样统计数字与真实运行状态吻合
