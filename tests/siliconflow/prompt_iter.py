#!/usr/bin/env python3
"""只改提示词、不换模型：用已缓存的 ASR 原文（tl-results.json 里 Qwen3-ASR-1.7B 那组）重跑整理，
对比各提示词版本和 Typeless 整理结果的接近程度。前 40 条当调优集、后 20 条当留出集（防过拟合）。
用法：SILICONFLOW_API_KEY=... python3 prompt_iter.py v1 [v2 ...]   （v0 = App 当前默认）"""
import json, os, re, statistics, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import server, bench, bench_or

HERE = Path(__file__).parent; KEY = os.environ["SILICONFLOW_API_KEY"]
GLOSS = (HERE / "glossary.txt").read_text(encoding="utf-8")
data = [x for x in json.load(open(HERE / "tl-results.json"))["Qwen/Qwen3-ASR-1.7B"] if x["asr_ok"] and x["raw"]]
V = {"v0": bench_or.PROMPT}
RULE4 = next(l for l in bench_or.PROMPT.split("\n") if l.startswith("4. 整理的原则"))
def variant(name, repl):
    p = bench_or.PROMPT.replace(RULE4, repl[0]) if repl[0] else bench_or.PROMPT
    for a, b in repl[1:]: p = p.replace(a, b)
    V[name] = p
exec(open(HERE / "prompt_variants.py", encoding="utf-8").read())

def run(job):
    name, x = job
    system = V[name].replace("{EXTRA}", "").replace("{GLOSSARY}", GLOSS).replace("{APP}", "备忘录")
    base = {"model": "deepseek-ai/DeepSeek-V4.1-Flash", "messages": [{"role": "system", "content": system}, {"role": "user", "content": x["raw"]}],
            "temperature": 0, "max_tokens": 1500, "stream": False, "enable_thinking": False}
    try: return (server.post_json("/chat/completions", base, KEY, 60)["choices"][0]["message"].get("content") or "").strip()
    except Exception as e: return ""
names = sys.argv[1:] or ["v0"]
jobs = [(n, x) for n in names for x in data]
with ThreadPoolExecutor(max_workers=6) as ex: outs = list(ex.map(run, jobs))
def L(s): return len(re.sub(r"\W", "", s))
print(f"{len(data)} 条（调优集 40 / 留出集 {len(data)-40}），参照 = Typeless 整理结果；ASR 固定为 Qwen3-ASR-1.7B")
print(f"{'版本':6} {'调优集CER':>9} {'留出集CER':>9} {'全部':>7} {'长度比':>6} {'分段一致':>8} {'空输出':>5}")
store = {}
for n in names:
    rs = [(x, o) for (nn, x), o in zip(jobs, outs) if nn == n]; store[n] = rs
    c = [bench.cer(o, x["ref"]) if o else 1.0 for x, o in rs]
    para = sum((x["ref_paras"] > 1) == (len([p for p in o.split("\n") if p.strip()]) > 1) for x, o in rs) / len(rs)
    print(f"{n:6} {statistics.mean(c[:40])*100:8.1f}% {statistics.mean(c[40:])*100:8.1f}% {statistics.mean(c)*100:6.1f}% {statistics.mean(L(o)/max(1,L(x['ref'])) for x,o in rs):6.2f} {para*100:7.0f}% {sum(not o for _,o in rs):>5}")
json.dump({n: [{"id": x["id"], "out": o} for x, o in rs] for n, rs in store.items()}, open("/tmp/prompt_iter_out.json", "w"), ensure_ascii=False)
