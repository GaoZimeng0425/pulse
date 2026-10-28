# 06: AI 模型分组(Ollama 内容寻址)+ 孤儿 worktree

**What to build:** 两个高收益规则域,全部骑 04 的规则表与清单管线。AI 模型:Ollama 按 01 探针的 manifest 实测解析内容寻址存储,算**真实可回收量**(两模型共享 blob 不重复计、也从不在另一个模型脚下抽走);LM Studio、HuggingFace 缓存(HF_HOME / HF_HUB_CACHE 荣誉);~/.cache、~/Library/Caches 等处无主 >100MB 权重文件的兜底列举(按所在文件夹列,写明"哪个 app 下载的")。孤儿 worktree:git worktree list 不登记 ∧ 无进程活动才列;git 仍登记的、终端 / agent 正在里面的,再旧也绝不出现;AI 编码工具(Cursor / Codex / Claude Code 等)的 worktree 遗留是主场景(用户自己的 .worktrees/ 约定)。

**Blocked by:** 04(与 05 并行)

**Status:** ready-for-agent

- [ ] Ollama 共享 blob 场景:显示的可回收量 = 去重后真值(夹具 manifest 测试)
- [ ] HF_HOME / HF_HUB_CACHE 环境变量路径荣誉有测试
- [ ] 无主大权重兜底列举按文件夹分组、带说明
- [ ] 孤儿 worktree:git 登记的 / 有终端在内的不出现(夹具测试)
- [ ] 本机实测口味:Ollama 真实模型行上屏(数字互验留 09 目验)
