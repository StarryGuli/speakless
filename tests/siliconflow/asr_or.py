#!/usr/bin/env python3
"""OpenRouter 音频输入模型的转写准确度对比（和 SiliconFlow 的 Qwen3-ASR 基线对照）。
用例：真实录音 round1/round2（recordings/，不入库）+ 用 macOS say 合成的 16 条中英夹杂句。
提示词带术语表，模拟"上下文提示"。结果写 asr-or-results.json。"""
import base64, json, os, statistics, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import bench

HERE = Path(__file__).parent; KEY = os.environ.get("OPENROUTER_API_KEY", "")
def _catalog():
    p = Path("/tmp/or_models.json")
    if not p.exists(): p.write_bytes(urllib.request.urlopen("https://openrouter.ai/api/v1/models").read())
    return {m["id"]: m for m in json.load(open(p))["data"]}
CATALOG = _catalog()
MODELS = ["google/gemini-2.5-flash", "google/gemini-2.5-flash-lite", "google/gemini-3.1-flash-lite", "google/gemini-3.5-flash-lite",
          "google/gemini-3-flash-preview", "google/gemini-3.8-flash", "openai/gpt-audio-mini", "mistralai/voxtral-small-24b-2507",
          "qwen/qwen3.8-omni-flash", "xiaomi/mimo-v2.6-flash"]
GLOSS = (HERE / "glossary.txt").read_text(encoding="utf-8").replace("\n", "、")
PROMPT = ("请逐字转写这段音频里的人声，只输出转写文字，不要解释。保持说话人的语言（中文、英文或中英混说），不要翻译，中文用简体。"
          "遇到下列专有名词时用这里的写法：" + GLOSS)

def cases():
    if os.environ.get("TL"):
        return [{"id": x["id"], "g": "real", "wav": Path(f"/tmp/tl_wav/{x['id']}.wav"), "ref": x["ref"], "terms": []} for x in json.load(open("/tmp/tl_sample.json"))]
    out = []
    for rd in ("round1", "round2"):
        ref, terms = bench.REAL_REFS[rd]
        out.append({"id": rd, "g": "real", "wav": HERE / "recordings" / f"{rd}.wav", "ref": ref, "terms": terms})
    for i, (g, inp, ref, terms) in enumerate(bench.SYNTH, 1):
        out.append({"id": f"s{i:02d}", "g": "syn", "wav": Path(f"/tmp/asr_wav/s{i:02d}.wav"), "ref": ref, "terms": terms})
    return out

def call(model, wav):
    b64 = base64.b64encode(wav.read_bytes()).decode()
    body = {"model": model, "temperature": 0, "max_tokens": 1500, "reasoning": {"enabled": False},
            "messages": [{"role": "user", "content": [{"type": "text", "text": PROMPT}, {"type": "input_audio", "input_audio": {"data": b64, "format": "wav"}}]}]}
    for attempt in (0, 1):
        t0 = time.time()
        try:
            req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", json.dumps(body).encode(), {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=120)); u = r.get("usage", {})
            return {"ok": True, "text": (r["choices"][0]["message"].get("content") or "").strip(), "ms": int((time.time() - t0) * 1000), "pt": u.get("prompt_tokens", 0), "ct": u.get("completion_tokens", 0)}
        except Exception as e:
            msg = str(e)
            if hasattr(e, "read"):
                try: msg = e.read().decode()[:300]
                except Exception: pass
            if attempt == 0 and "reasoning" in msg.lower(): body.pop("reasoning", None); continue
            return {"ok": False, "text": "", "ms": 0, "pt": 0, "ct": 0, "error": msg[:200]}

def main():
    models = [m for m in (sys.argv[1:] or MODELS) if m in CATALOG or print("skip", m)]
    cs = cases(); jobs = [(m, c) for m in models for c in cs]
    with ThreadPoolExecutor(max_workers=8) as ex: outs = list(ex.map(lambda j: call(j[0], j[1]["wav"]), jobs))
    res = {m: [] for m in models}
    for (m, c), o in zip(jobs, outs):
        res[m].append({**c, "wav": c["wav"].name, **o, "cer": bench.cer(o["text"], c["ref"]) if o["ok"] else 1.0,
                       "hit": [bench.norm(t) in bench.norm(o["text"]) for t in c["terms"]] if o["ok"] else [False] * len(c["terms"])})
    rows = []
    for m, rs in res.items():
        real = [r for r in rs if r["g"] == "real"]; syn = [r for r in rs if r["g"] == "syn"]
        hits = [h for r in rs for h in r["hit"]]; p = CATALOG[m]["pricing"]
        cost = sum(r["pt"] * float(p["prompt"]) + r["ct"] * float(p["completion"]) for r in rs)
        rows.append({"id": m, "cer_real": round(statistics.mean(r["cer"] for r in real), 4), "cer_syn": round(statistics.mean(r["cer"] for r in syn), 4),
                     "term": round(sum(hits) / max(1, len(hits)), 3), "ms": round(statistics.median([r["ms"] for r in rs if r["ok"]] or [0])),
                     "cost_1k": round(cost / len(rs) * 1000, 3), "fails": sum(not r["ok"] for r in rs), "err": next((r.get("error") for r in rs if not r["ok"]), None)})
    (HERE / "asr-or-results.json").write_text(json.dumps({"generated": time.strftime("%Y-%m-%d %H:%M"), "rows": rows, "detail": {m: [{k: v for k, v in r.items() if k != "wav"} for r in rs] for m, rs in res.items()}}, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    print(f"{'模型':34} {'真实CER':>7} {'合成CER':>7} {'词命中':>6} {'中位ms':>7} {'$/千条':>7} 失败")
    for r in sorted(rows, key=lambda r: r["cer_real"]):
        print(f"{r['id']:34} {r['cer_real']*100:6.1f}% {r['cer_syn']*100:6.1f}% {r['term']*100:5.0f}% {r['ms']:>7} {r['cost_1k']:>7} {r['fails']}" + (f" ERR {r['err'][:80]}" if r['err'] else ""))

if __name__ == "__main__":
    main()
