#!/bin/sh
# 探针 08 — root 独有数据盘点:powermetrics 单发 per-app 表(P3 探针②实机轮)
#
# 目的:回答「root helper 值不值」——powermetrics(root 独有)相对 Pulse 现有
# 免 root 管线(SMC 五路功率 / nettop 每进程流量 / IORegistry GPU)真增量是什么。
#
# 用法(须用户本人输 sudo 密码,agent 不代跑):
#   sudo powermetrics -n 1 -i 1000 --show-process-energy --show-process-gpu \
#     --show-process-netstats > docs/probes/08-powermetrics-root-data.output.txt
#
# 踩坑记档:
# - 默认 powermetrics 会连续采样直到 Ctrl-C,-n 1 单发是唯一不占机器的跑法
#   (keep-test-cpu-load-minimal 纪律:单次 ~1s,零持续负载)。
# - 表列顺序:Name ID CPUms/s User% Deadlines×2 Wakeups×2 PacketsIn/Out
#   BytesIn/Out GPUms/s EnergyImpact —— GPU 是倒数第二列、能耗是最后一列,
#   awk 判 GPU 非零用 $(NF-1)。
# - ⚠️ 本机 Mac16,1 / macOS 26A434:per-app GPU 列存在但窗口内全 0.00,同窗口
#   全机 GPU HW active residency 却有 50.54%(桌面合成)——per-app GPU 归因
#   在这台机器上疑似拿不到,与 Stats 参考 repo 的 M4 家族 GPU caveat 一致。
#   定论须重 GPU 负载复测(本窗口无重负载,不算失败,算「未触发」)。
set -eu
echo "本探针须用户本人跑(见头注释),此脚本仅存档命令与口径。" >&2
exit 0
