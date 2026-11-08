#!/usr/bin/env python3
"""OpenRouter 纠错/整理模型对比：用 App 当前默认提示词，测错字率、专有词、不误改、分段/列表格式、耗时、费用。
用法：OPENROUTER_API_KEY=... python3 bench_or.py [模型id ...]   结果写 bench-or-results.json
"""
import json, os, re, statistics, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import bench

HERE = Path(__file__).parent
KEY = os.environ.get("OPENROUTER_API_KEY", "")
SWIFT = HERE.parent.parent / "app/Sources/Speakless/API.swift"
def _catalog():
    p = Path("/tmp/or_models.json")
    if not p.exists(): p.write_bytes(urllib.request.urlopen("https://openrouter.ai/api/v1/models").read())
    return {m["id"]: m for m in json.load(open(p))["data"]}
CATALOG = _catalog()

MODELS = ["google/gemini-3.8-flash", "google/gemini-3.5-flash-lite", "z-ai/glm-5.3-flash", "z-ai/glm-5.3-flashx", "z-ai/glm-5.3",
          "deepseek/deepseek-v4.1-flash", "qwen/qwen3.8-flash", "qwen/qwen3.8-27b", "anthropic/claude-haiku-5.5",
          "openai/gpt-5.6-luna", "minimax/minimax-m3.1-flash", "xiaomi/mimo-v2.6-flash", "mistralai/mistral-large-4-0", "inclusionai/ling-3.1-flash"]
EXTRA_MODELS = [i for i in CATALOG if any(k in i for k in ("gpt-oss-120b", "llama-3.3-70b", "kimi-k2")) and ":" not in i]

def load_prompt():
    s = SWIFT.read_text(encoding="utf-8")
    a = s.index('static let polish = """'); a = s.index("\n", a) + 1
    b = s.index('\n    """', a)
    return "\n".join(l[4:] if l.startswith("    ") else l for l in s[a:b].split("\n"))
PROMPT = load_prompt()

# 格式用例：(app, 输入, 最少段数, 最少编号条数, 必须保留的词, 是否应保持简短一段)
FMT = [
 ("Claude", "我感觉我们的这个听写对于像我现在这样跟 AI 输入的时候 分段还不是很明显 自动整理格式就是一段一段的 这个整理得不好 经常都是一大串文字横在那里输出 没有任何格式 换行也不怎么用 序号也不怎么用 你看看怎么改一下提示词 然后测一下", 2, 0, ["分段", "序号", "提示词"], False),
 ("Claude", "然后我想让你看一下那个预热的功能 现在的问题是第一次识别特别慢 大概要等一百秒 我怀疑是模型没提前加载 你先查一下日志看看有没有请求发出去 另外开关默认应该是关的 因为这个接口不是标准的 如果别人的服务不支持就会报错 最后帮我把这个说明写到设置页里面", 2, 3, ["日志", "默认", "设置页"], False),
 ("备忘录", "明天要去取快递 然后买牛奶和鸡蛋 还有给妈妈打个电话 对了下午三点要开组会", 1, 3, ["快递", "牛奶", "组会"], False),
 ("微信", "哈哈你来不来 我们晚上吃火锅 你要是来的话我就订位置了", 1, 0, ["火锅", "订位置"], True),
 ("ChatGPT", "Whisper large v3 turbo 和 Qwen3 ASR 在中文口语上哪个更准 帮我对比一下", 1, 0, ["Whisper", "Qwen3"], True),
 ("Claude", "帮我重构一下登录模块 首先把校验逻辑抽成单独的函数 然后给它补上单元测试 最后把旧的接口标记为废弃 注意不要改对外的返回格式", 1, 3, ["校验", "单元测试", "废弃", "返回格式"], False),
 ("备忘录", "今天的会议主要定了三件事 一个是下周三发版 一个是预算要重新报 还有就是新人的培训由小王负责", 1, 3, ["下周三", "预算", "培训"], False),
 ("Mail", "老师您好 我想请问下周的组会能不能改到周四 因为我周三有课 另外上次实验的数据我已经整理好了 想问要不要提前发给您看 谢谢老师", 3, 0, ["周四", "数据", "谢谢"], False),
]
MD = re.compile(r"\*\*|^#+ |`|^\s*[-*] ", re.M)

def call(model, system, user):
    body = {"model": model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "temperature": 0, "max_tokens": 2500, "reasoning": {"enabled": False}}
    for attempt in (0, 1):
        t0 = time.time()
        try:
            req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", json.dumps(body).encode(),
                                         {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=90))
            ms = int((time.time() - t0) * 1000)
            txt = (r["choices"][0]["message"].get("content") or "").strip()
            u = r.get("usage", {})
            return {"ok": bool(txt), "text": txt, "ms": ms, "pt": u.get("prompt_tokens", 0), "ct": u.get("completion_tokens", 0)}
        except Exception as e:
            msg = str(e)
            if hasattr(e, "read"):
                try: msg = e.read().decode()[:300]
                except Exception: pass
            if attempt == 0 and "reasoning" in msg.lower():
                body.pop("reasoning", None); continue
            return {"ok": False, "text": "", "ms": int((time.time() - t0) * 1000), "pt": 0, "ct": 0, "error": msg[:200]}

def sysprompt(app, glossary):
    return PROMPT.replace("{EXTRA}", "").replace("{GLOSSARY}", glossary).replace("{APP}", app)

def fmt_score(out, c):
    app, inp, minp, minl, must, short = c
    paras = [p for p in re.split(r"\n\s*\n", out.strip()) if p.strip()]
    lists = len(re.findall(r"^\s*\d+[.、)]", out, re.M))
    keep = sum(bench.norm(w) in bench.norm(out) for w in must) / len(must)
    ok_struct = len(paras) >= minp and lists >= minl and not MD.search(out)
    if short: ok_struct = len(paras) == 1 and lists == 0 and not MD.search(out)
    return {"struct": ok_struct, "keep": keep, "paras": len(paras), "lists": lists}

def main():
    if not KEY: sys.exit("没有 OPENROUTER_API_KEY")
    models = sys.argv[1:] or (MODELS + EXTRA_MODELS)
    models = [m for m in models if m in CATALOG or print("不在目录里，跳过:", m)]
    glossary = (HERE / "glossary.txt").read_text(encoding="utf-8")
    acc = [{"k": f"s{i}", "g": "syn", "in": c[1], "ref": c[2], "terms": c[3], "app": "备忘录"} for i, c in enumerate(bench.SYNTH, 1)]
    acc += [{"k": f"c{i}", "g": "clean", "in": t, "ref": t, "terms": [], "app": "微信"} for i, t in enumerate(bench.CLEAN, 1)]
    jobs = [(m, c) for m in models for c in acc] + [(m, ("F", f)) for m in models for f in FMT]
    def run(j):
        m, c = j
        if isinstance(c, tuple): return call(m, sysprompt(c[1][0], glossary), c[1][1])
        return call(m, sysprompt(c["app"], glossary), c["in"])
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=10) as ex: outs = list(ex.map(run, jobs))
    print(f"完成 {len(jobs)} 次调用，用时 {time.time()-t0:.0f}s")
    res = {m: {"acc": [], "fmt": [], "fails": 0, "lat": [], "cost": 0.0, "err": None} for m in models}
    for (m, c), o in zip(jobs, outs):
        r = res[m]; p = CATALOG[m]["pricing"]
        r["cost"] += o["pt"] * float(p["prompt"]) + o["ct"] * float(p["completion"])
        if not o["ok"]: r["fails"] += 1; r["err"] = r["err"] or o.get("error"); 
        else: r["lat"].append(o["ms"])
        if isinstance(c, tuple):
            r["fmt"].append({**(fmt_score(o["text"], c[1]) if o["ok"] else {"struct": False, "keep": 0, "paras": 0, "lists": 0}), "out": o["text"]})
        else:
            cer_v = bench.cer(o["text"], c["ref"]) if o["ok"] else 1.0
            hit = [bench.norm(t) in bench.norm(o["text"]) for t in c["terms"]] if o["ok"] else [False] * len(c["terms"])
            r["acc"].append({"g": c["g"], "cer": cer_v, "hit": hit, "exact": o["ok"] and bench.norm(o["text"]) == bench.norm(c["ref"])})
    rows = []
    for m, r in res.items():
        syn = [a for a in r["acc"] if a["g"] == "syn"]; cl = [a for a in r["acc"] if a["g"] == "clean"]
        hits = [h for a in syn for h in a["hit"]]
        n = len(r["acc"]) + len(r["fmt"])
        rows.append({"id": m, "cer": round(statistics.mean(a["cer"] for a in syn), 4), "term": round(sum(hits) / max(1, len(hits)), 3),
                     "clean": f"{sum(a['exact'] for a in cl)}/{len(cl)}", "fmt": f"{sum(f['struct'] for f in r['fmt'])}/{len(r['fmt'])}",
                     "keep": round(statistics.mean(f["keep"] for f in r["fmt"]), 2),
                     "lat": round(statistics.median(r["lat"])) if r["lat"] else None, "cost_1k": round(r["cost"] / n * 1000, 4), "fails": r["fails"], "err": r["err"]})
    (HERE / "bench-or-results.json").write_text(json.dumps({"generated": time.strftime("%Y-%m-%d %H:%M"), "rows": rows, "detail": res}, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{'模型':36} {'错字率':>6} {'词命中':>6} {'不误改':>6} {'格式':>5} {'保留':>5} {'中位ms':>7} {'$/千次':>7} 失败")
    for r in sorted(rows, key=lambda r: (-int(r['fmt'].split('/')[0]), r['cer'])):
        print(f"{r['id']:36} {r['cer']*100:5.1f}% {r['term']*100:5.0f}% {r['clean']:>6} {r['fmt']:>5} {r['keep']:>5} {r['lat'] or 0:>7} {r['cost_1k']:>7} {r['fails']}" + (f"  ERR {r['err'][:70]}" if r['err'] else ""))

if __name__ == "__main__":
    main()
