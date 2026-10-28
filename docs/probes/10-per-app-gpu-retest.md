# 探针 10:per-app GPU 复测(p3-root-mcp/04-②,2026-10-28)

**方法**:自编 Metal 计算压载 /tmp/gpu-stress(gpu-stress.swift,16M 线程 ×
2000 FMA 连续派发,GPU-bound——实测 CPU 仅 0.47 ms/s)+ root 采样
`powermetrics -n 1 -i 2000 --show-process-gpu`(用户 sudo 执行,压载跑 5s 自动杀)。

**结果**:gpu-stress(pid 62505)在进程表内而 GPU ms/s = **0.00**;同表
WindowServer(合成活跃,175 deadlines/s)与 "NeteaseMusic Helper (GPU)"
亦全 0.00。与探针 08 的"GPU HW residency 50% 时全表 0.00"互证。

**定论**:per-process GPU ms/s 列在 Mac16,1 / macOS 26A434 存在但恒 0,
本机不可用——如实记档放弃,不做 per-app GPU 卡(caveat 与 stats 参考 repo
的 M4/macOS 26 GPU caveat 一致)。复测成本极低:任何时间重跑上面一条命令即可。
