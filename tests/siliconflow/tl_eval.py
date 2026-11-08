#!/usr/bin/env python3
"""用 Typeless 本机保留的录音和它的整理结果做对照：看我们的 ASR + 整理离 Typeless 有多远。
参考答案 = Typeless 的 refined_text（不是说话内容的"真值"，衡量的是"接近 Typeless 的程度"）。
数据只在本机处理；结果写 tl-results.json（已 .gitignore，不入库）。
用法：SILICONFLOW_API_KEY=... python3 tl_eval.py [样本数]
"""
import json, os, statistics, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import server, bench, bench_or

HERE = Path(__file__).parent; KEY = os.environ["SILICONFLOW_API_KEY"]
N = int(sys.argv[1]) if len(sys.argv) > 1 else 60
ASRS = ["Qwen/Qwen3-ASR-1.7B", "XingChenAGI/XingChenASR-V3.2-Ultra", "Qwen/Qwen3-Omni-30B-A3B-Instruct"]
CORR = "deepseek-ai/DeepSeek-V4.1-Flash"
GLOSS = (HERE / "glossary.txt").read_text(encoding="utf-8")
samples = json.load(open("/tmp/tl_sample.json"))[:N]
os.makedirs("/tmp/tl_wav", exist_ok=True)
for s in samples:
    s["wav"] = f"/tmp/tl_wav/{s['id']}.wav"
    if not os.path.exists(s["wav"]):
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", s["path"], "-ar", "16000", "-ac", "1", s["wav"]], check=True)

def asr(job):
    m, s = job
    spec = next(x for x in server.MODELS if x["id"] == m)
    return server.transcribe(spec, open(s["wav"], "rb").read(), KEY)

def fix(job):
    text, = job
    base = {"model": CORR, "messages": [{"role": "system", "content": bench_or.sysprompt("备忘录", GLOSS)}, {"role": "user", "content": text}],
            "temperature": 0, "max_tokens": 1500, "stream": False, "enable_thinking": False}
    t0 = time.time()
    try:
        out = server.post_json("/chat/completions", base, KEY, 60)
        return {"ok": True, "text": (out["choices"][0]["message"].get("content") or "").strip(), "ms": int((time.time() - t0) * 1000)}
    except Exception as e:
        return {"ok": False, "text": "", "ms": 0, "error": str(e)[:120]}

jobs = [(m, s) for m in ASRS for s in samples]
with ThreadPoolExecutor(max_workers=6) as ex: raw = list(ex.map(asr, jobs))
with ThreadPoolExecutor(max_workers=6) as ex: fixed = list(ex.map(fix, [(r["text"] if r["ok"] else "",) for r in raw]))
res = {}
for (m, s), r, f in zip(jobs, raw, fixed):
    res.setdefault(m, []).append({"id": s["id"], "dur": s["dur"], "ref": s["ref"], "raw": r.get("text", ""), "asr_ms": r["ms"], "asr_ok": r["ok"],
        "out": f["text"], "fix_ok": f["ok"], "cer_raw": bench.cer(r.get("text", ""), s["ref"]) if r["ok"] else 1.0,
        "cer_out": bench.cer(f["text"], s["ref"]) if f["ok"] and r["ok"] else 1.0,
        "ref_paras": len([p for p in s["ref"].split("\n") if p.strip()]), "out_paras": len([p for p in f["text"].split("\n") if p.strip()])})
(HERE / "tl-results.json").write_text(json.dumps(res, ensure_ascii=False, indent=1), encoding="utf-8")
print(f"{len(samples)} 条录音（共 {sum(s['dur'] for s in samples):.0f} 秒），参考 = Typeless 的整理结果")
print(f"{'ASR':40} {'原始CER':>8} {'整理后CER':>9} {'ASR中位ms':>9} {'失败':>4}  分段一致")
for m, rs in res.items():
    ok = [r for r in rs if r["asr_ok"]]
    para = sum((r["ref_paras"] > 1) == (r["out_paras"] > 1) for r in rs) / len(rs)
    print(f"{m:40} {statistics.mean(r['cer_raw'] for r in rs)*100:7.1f}% {statistics.mean(r['cer_out'] for r in rs)*100:8.1f}% {statistics.median(r['asr_ms'] for r in ok) if ok else 0:>9} {len(rs)-len(ok):>4}  {para*100:.0f}%")
