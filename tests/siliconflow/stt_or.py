#!/usr/bin/env python3
"""OpenRouter 专用转写（/audio/transcriptions）模型对比。用 Typeless 本机录音 + 它的整理结果做参照（只在本机处理）。
每个模型跑两遍：A 只传音频；B 另传 language=zh 和术语提示。转写后再用 App 的默认整理提示词整理一遍，看"整条流水线"离 Typeless 多远。
用法：OPENROUTER_API_KEY=... SILICONFLOW_API_KEY=... python3 stt_or.py [样本数]"""
import base64, json, os, statistics, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import server, bench, bench_or

HERE = Path(__file__).parent; OR = os.environ["OPENROUTER_API_KEY"]; SF = os.environ["SILICONFLOW_API_KEY"]
N = int(sys.argv[1]) if len(sys.argv) > 1 else 60
MODELS = ["qwen/qwen3-asr-0.6b", "openai/gpt-transcribe", "fish-audio/transcribe-1", "x-ai/grok-stt-1.0", "deepgram/nova-3", "microsoft/mai-transcribe-1.5",
          "nvidia/parakeet-tdt-0.6b-v3", "mistralai/voxtral-mini-transcribe", "google/chirp-3", "openai/gpt-4o-mini-transcribe", "openai/gpt-4o-transcribe",
          "openai/whisper-large-v3-turbo", "openai/whisper-large-v3", "openai/whisper-1"]
EXTRA = len(sys.argv) > 2
if EXTRA: MODELS = sys.argv[2:]
GLOSS = (HERE / "glossary.txt").read_text(encoding="utf-8")
HINT = "中文口述，常夹杂英文技术名词。术语：" + "、".join(l.split(" / ")[0] for l in GLOSS.splitlines() if l.strip())
samples = json.load(open("/tmp/tl_sample.json"))[:N]
for s in samples: s["wav"] = f"/tmp/tl_wav/{s['id']}.wav"

def stt(job):
    m, s, hinted = job
    b64 = base64.b64encode(open(s["wav"], "rb").read()).decode()
    body = {"model": m, "input_audio": {"data": b64, "format": "wav"}}
    if hinted: body |= {"language": "zh", "prompt": HINT}
    t0 = time.time()
    try:
        r = urllib.request.Request("https://openrouter.ai/api/v1/audio/transcriptions", json.dumps(body).encode(), {"Authorization": "Bearer " + OR, "Content-Type": "application/json"})
        o = json.load(urllib.request.urlopen(r, timeout=120))
        return {"ok": True, "text": (o.get("text") or "").strip(), "ms": int((time.time() - t0) * 1000), "cost": (o.get("usage") or {}).get("cost") or 0}
    except Exception as e:
        msg = str(e)
        if hasattr(e, "read"):
            try: msg = e.read().decode()[:200]
            except Exception: pass
        return {"ok": False, "text": "", "ms": 0, "cost": 0, "error": msg}

def fix(text):
    if not text: return ""
    base = {"model": "deepseek-ai/DeepSeek-V4.1-Flash", "messages": [{"role": "system", "content": bench_or.sysprompt("备忘录", GLOSS)}, {"role": "user", "content": text}],
            "temperature": 0, "max_tokens": 1500, "stream": False, "enable_thinking": False}
    try: return (server.post_json("/chat/completions", base, SF, 60)["choices"][0]["message"].get("content") or "").strip()
    except Exception: return ""

jobs = [(m, s, h) for m in MODELS for h in (False, True) for s in samples]
with ThreadPoolExecutor(max_workers=8) as ex: raws = list(ex.map(stt, jobs))
with ThreadPoolExecutor(max_workers=8) as ex: fixed = list(ex.map(fix, [r["text"] for r in raws]))
res = {}
for (m, s, h), r, f in zip(jobs, raws, fixed):
    res.setdefault((m, h), []).append({"id": s["id"], "ref": s["ref"], "raw": r["text"], "out": f, "ms": r["ms"], "ok": r["ok"], "cost": r["cost"], "error": r.get("error"),
        "cer_raw": bench.cer(r["text"], s["ref"]) if r["ok"] else 1.0, "cer_out": bench.cer(f, s["ref"]) if r["ok"] and f else 1.0})
rows = []
for (m, h), rs in res.items():
    ok = [x for x in rs if x["ok"]]
    rows.append({"model": m, "hint": h, "cer_raw": statistics.mean(x["cer_raw"] for x in rs), "cer_out": statistics.mean(x["cer_out"] for x in rs),
                 "ms": statistics.median(x["ms"] for x in ok) if ok else 0, "cost": sum(x["cost"] for x in rs), "fails": len(rs) - len(ok), "err": next((x["error"] for x in rs if x["error"]), None)})
(HERE / ("stt-or-results-extra.json" if EXTRA else "stt-or-results.json")).write_text(json.dumps({"generated": time.strftime("%Y-%m-%d %H:%M"), "n": len(samples), "rows": rows, "detail": {f"{m}|{h}": v for (m, h), v in res.items()}}, ensure_ascii=False, indent=1), encoding="utf-8")
print(f"{len(samples)} 条 / {sum(s['dur'] for s in samples):.0f} 秒；参照 = Typeless 整理结果。基线 Qwen3-ASR-1.7B：原始 25.4% → 整理后 22.7%")
print(f"{'模型':36} {'提示':>4} {'原始CER':>8} {'整理后':>7} {'中位ms':>7} {'花费$':>7} 失败")
for r in sorted(rows, key=lambda r: r["cer_out"]):
    print(f"{r['model']:36} {'B' if r['hint'] else 'A':>4} {r['cer_raw']*100:7.1f}% {r['cer_out']*100:6.1f}% {r['ms']:>7.0f} {r['cost']:>7.3f} {r['fails']}" + (f"  ERR {r['err'][:60]}" if r["err"] else ""))
