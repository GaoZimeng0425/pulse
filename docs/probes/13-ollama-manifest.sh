#!/bin/bash
# 13-ollama-manifest.sh — p4-cleaner/01 探针③:Ollama 内容寻址实测 + LM Studio / HuggingFace 形状
# 问:manifest/blobs 真实结构;两模型共享 blob 的去重验证(06 票"真实可回收量"算法输入);HF_HOME/HF_HUB_CACHE 是否在场。
set -u
OLM="$HOME/.ollama/models"

echo "== ① Ollama 目录形状 =="
du -sh "$OLM" 2>/dev/null
echo "-- manifests 树(前 12 行):"
find "$OLM/manifests" -type f 2>/dev/null | head -12
echo "-- blobs 条目数: $(ls -A "$OLM/blobs" 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "== ② manifest JSON 样本 =="
M=$(find "$OLM/manifests" -type f 2>/dev/null | head -1)
echo "样本: $M"
cat "$M" 2>/dev/null | head -40

echo
echo "== ③ 共享 blob 去重验证(全部模型两两) =="
python3 - "$OLM" <<'PY'
import json, os, sys, hashlib
olm = sys.argv[1]
blobs = os.path.join(olm, "blobs")
# blob 文件名 = sha256:<digest>(文件名里冒号转成 -)
models = {}   # manifest 路径 -> [digest...]
for root, _, files in os.walk(os.path.join(olm, "manifests")):
    for f in files:
        p = os.path.join(root, f)
        try:
            m = json.load(open(p))
        except Exception as e:
            print(f"  解析失败 {p}: {e}"); continue
        digests = []
        for layer in m.get("layers", []) + [m.get("config", {})]:
            d = layer.get("digest")
            if d: digests.append(d)
        models["/".join(p.split("/")[-3:])] = digests
size = {}
for f in os.listdir(blobs):
    d = "sha256:" + f.replace("sha256-", "")
    try: size[d] = os.path.getsize(os.path.join(blobs, f))
    except OSError: pass
total = sum(size.values())
seen = {}
shared_bytes = 0
for name, ds in sorted(models.items()):
    uniq = 0
    for d in ds:
        if d in size:
            seen[d] = seen.get(d, 0) + 1
for d, n in seen.items():
    if n > 1: shared_bytes += size[d]
print(f"  模型数: {len(models)} · blob 文件: {len(size)} · blobs 总占用: {total/2**30:.2f} GiB")
print(f"  被多个模型引用的 blob: {sum(1 for n in seen.values() if n>1)} 个 · 共享字节: {shared_bytes/2**30:.2f} GiB")
print(f"  → 同时删全部模型才回收 {total/2**30:.2f} GiB;只删一个,共享层不释放 —— '真实可回收量'必须按 manifest 引用算")
for name, ds in sorted(models.items()):
    own = sum(size.get(d, 0) for d in set(ds))
    print(f"    {name}: 引用 {len(set(ds))} 个 blob,表观 {own/2**30:.2f} GiB")
PY

echo
echo "== ④ LM Studio / HuggingFace / 其他模型库在场性 =="
for d in ~/.lmstudio ~/.cache/lm-studio ~/.cache/huggingface "$HOME/Library/Caches/huggingface" ~/.cache/whisper ~/Library/Application\ Support/Jan ~/GPT4All; do
  if [ -e "$d" ]; then echo "  存在: $d ($(du -sh "$d" 2>/dev/null | cut -f1))"; else echo "  不存在: $d"; fi
done
echo "  HF_HOME=${HF_HOME:-未设} HF_HUB_CACHE=${HF_HUB_CACHE:-未设}"
echo "  ollama 进程: $(pgrep -x ollama >/dev/null && echo 在跑 || echo 没在跑)(在跑的 ollama serve 模型目录在用——06 票在用保护素材)"
