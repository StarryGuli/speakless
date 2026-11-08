#!/usr/bin/env python3
"""纠错模型基准测试：对每个纠错模型跑同一批用例，算错字率、专有词命中、耗时，结果写到 bench-results.json。

用例分三类：
  real      真实录音经 3 个识别模型出来的文字（参考答案是我按说话内容整理的，第 3 段没有参考答案，不计分）
  synthetic 手写的、带典型识别错误的中英夹杂句子（参考答案已知）
  clean     本来就对的句子，纠错后应原样输出（测"误改"）
术语表用 glossary.txt，里面只有正确写法，没有"常被听成什么"，避免泄题。
"""
import json
import re
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import server

HERE = Path(__file__).parent
ASR_RESULTS = Path("/private/tmp/claude-501/asr-results")
ASR_TOP = server.ASR_TOP

REAL_REFS = {
    "round1": ("哪个最贵啊？我这边这个千问3是最快最准的，但是它也不是很准。但是现在是哪个最贵啊？你告诉我。", ["千问", "最快", "最准", "最贵"]),
    "round2": ("我现在是这样的，我注册了一个硅基流动，到时候会有一些API Key，可能会用来访问语音识别或者语音生成模型。"
               "我想把它们存在本地的环境变量里，应该怎么去保存这些数据呢？", ["硅基流动", "API Key", "环境变量"]),
    "round3": (None, []),
}

SYNTH = [
    ("infra", "我把dev二上的engine X配置改了一下，然后用PM二重启了后端", "我把 dev2 上的 nginx 配置改了一下，然后用 pm2 重启了后端。", ["dev2", "nginx", "pm2"]),
    ("tools", "帮我用cloud code把这个派森脚本里的request换成http x", "帮我用 Claude Code 把这个 Python 脚本里的 requests 换成 httpx。", ["Claude Code", "Python", "requests", "httpx"]),
    ("infra", "太尔斯凯尔的内网地址连不上，先拼一下再看SSH的日志", "Tailscale 的内网地址连不上，先 ping 一下再看 SSH 的日志。", ["Tailscale", "ping", "SSH"]),
    ("hardware", "ESP三十二通过web socket连到网关，心跳四十五秒没收到就判掉线", "ESP32 通过 WebSocket 连到网关，心跳 45 秒没收到就判掉线。", ["ESP32", "WebSocket", "45"]),
    ("hardware", "STM三十二的烧录用STM三十二cube programmer，platform IO里面选S T link", "STM32 的烧录用 STM32CubeProgrammer，PlatformIO 里面选 ST-Link。", ["STM32", "STM32CubeProgrammer", "PlatformIO"]),
    ("life", "把小红书的采集只放在Mac book上跑，别放到V P S，不然Cookie会触发风空", "把小红书的采集只放在 MacBook 上跑，别放到 VPS，不然 cookie 会触发风控。", ["小红书", "MacBook", "VPS", "风控"]),
    ("life", "雅思听力section三的题我错了四个，主要是map题", "雅思听力 Section 3 的题我错了四个，主要是 map 题。", ["雅思", "Section", "map"]),
    ("tools", "我想用mini max做TTS，但是每次都要先问我，别乱花钱", "我想用 MiniMax 做 TTS，但是每次都要先问我，别乱花钱。", ["MiniMax", "TTS"]),
    ("tools", "Git hub上默认建私苦，推之前先扫一遍有没有托肯", "GitHub 上默认建私库，推之前先扫一遍有没有 token。", ["GitHub", "私库", "token"]),
    ("tools", "归机流动的API Key放到点z s h r c里，然后搜斯一下", "硅基流动的 API Key 放到 .zshrc 里，然后 source 一下。", ["硅基流动", "API Key", ".zshrc", "source"]),
    ("tools", "千万三的ASR又快又准，但是专有名词还是会听错", "千问 3 的 ASR 又快又准，但是专有名词还是会听错。", ["千问", "ASR"]),
    ("script", "我現在是這樣子的，我想把它們保存在本地的環境變數裡面", "我现在是这样子的，我想把它们保存在本地的环境变量里面。", ["环境变量"]),
    ("script", "呃，那个，我想，嗯，把这个PDF转成Word", "我想把这个 PDF 转成 Word。", ["PDF", "Word"]),
    ("code", "把get下划线user下划线info这个函数改成驼峰命名，加上a sync", "把 get_user_info 这个函数改成驼峰命名，加上 async。", ["get_user_info", "async"]),
    ("code", "我dipoy了一下新版本，现在health check是green的", "我 deploy 了一下新版本，现在 health check 是 green 的。", ["deploy", "health check"]),
    ("tools", "我在O B S I D I A N里面写了雅思的日志，然后用Python脚本整理", "我在 Obsidian 里面写了雅思的日志，然后用 Python 脚本整理。", ["Obsidian", "雅思", "Python"]),
    ("infra", "Open claw的gateway又崩了，先看一下端口有没有被占", "OpenClaw 的 gateway 又崩了，先看一下端口有没有被占。", ["OpenClaw", "gateway"]),
]
CLEAN = [
    "今天天气不错，我们下午三点开会。",
    "这个 bug 是 React 的 useEffect 依赖数组写错了。",
    "这个方案最贵，但是最准。",
    "Let me check the nginx log and then restart the service.",
]


def norm(s: str) -> str:
    return re.sub(r"[^\w]|_", "", s.lower())


def lev(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def cer(out: str, ref: str) -> float:
    r = norm(ref)
    return lev(norm(out), r) / max(1, len(r))


def build_cases():
    cases = []
    asr_ms = {}
    for rd in ("round1", "round2", "round3"):
        data = json.load(open(ASR_RESULTS / f"{rd}.json"))
        ref, terms = REAL_REFS[rd]
        for r in data["results"]:
            if r["model"] in ASR_TOP and r["ok"]:
                cases.append({"id": f"{rd}|{r['model'].split('/')[-1]}", "group": "real", "asr": r["model"], "round": rd,
                              "input": r["text"], "ref": ref, "terms": terms})
                asr_ms.setdefault(r["model"], []).append(r["ms"])
    for i, (g, inp, ref, terms) in enumerate(SYNTH, 1):
        cases.append({"id": f"s{i:02d}", "group": "synthetic", "topic": g, "input": inp, "ref": ref, "terms": terms})
    for i, t in enumerate(CLEAN, 1):
        cases.append({"id": f"c{i:02d}", "group": "clean", "input": t, "ref": t,
                      "terms": ["React", "useEffect"] if "React" in t else (["最贵", "最准"] if "最贵" in t else [])})
    return cases, {k: round(statistics.mean(v)) for k, v in asr_ms.items()}


def main():
    key = server.os.environ.get("SILICONFLOW_API_KEY", "")
    if not key:
        sys.exit("没有 SILICONFLOW_API_KEY")
    glossary = server.read_glossary()
    cases, asr_ms = build_cases()
    correctors = server.CORRECTORS
    print(f"{len(cases)} 个用例 × {len(correctors)} 个纠错模型 = {len(cases) * len(correctors)} 次调用")

    # 1) 准确度：全部并发
    jobs = [(c, case) for c in correctors for case in cases]
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=8) as pool:
        outs = list(pool.map(lambda j: server.correct(j[0]["id"], j[1]["input"], glossary, key), jobs))
    print(f"准确度测试完成，用时 {time.time() - t0:.0f}s")
    by = {}
    for (c, case), o in zip(jobs, outs):
        by.setdefault(case["id"], {})[c["id"]] = o

    # 2) 延迟：每个模型串行跑 5 条真实输入（模型之间并行），代表单次使用的耗时
    lat_cases = [c for c in cases if c["group"] == "real"][:5]

    def lat_run(c):
        return [server.correct(c["id"], lc["input"], glossary, key)["ms"] for lc in lat_cases]
    with ThreadPoolExecutor(max_workers=len(correctors)) as pool:
        lats = dict(zip([c["id"] for c in correctors], pool.map(lat_run, correctors)))

    # 3) 汇总
    rows = []
    for c in correctors:
        cid = c["id"]
        scored = [k for k in cases if k["ref"]]
        ok = lambda k: by[k["id"]][cid]["ok"]
        cers = {k["id"]: (cer(by[k["id"]][cid]["text"], k["ref"]) if ok(k) else 1.0) for k in scored}
        raw = {k["id"]: cer(k["input"], k["ref"]) for k in scored}
        grp = lambda g, d: [d[k["id"]] for k in scored if k["group"] == g]
        hits = tot = 0
        for k in scored:
            for t in k["terms"]:
                tot += 1
                hits += ok(k) and norm(t) in norm(by[k["id"]][cid]["text"])
        clean = [k for k in cases if k["group"] == "clean"]
        clean_ok = sum(ok(k) and norm(by[k["id"]][cid]["text"]) == norm(k["ref"]) for k in clean)
        rows.append({
            "id": cid, "price": c["price"],
            "cer": round(statistics.mean(cers.values()), 4), "raw_cer": round(statistics.mean(raw.values()), 4),
            "cer_real": round(statistics.mean(grp("real", cers)), 4), "raw_real": round(statistics.mean(grp("real", raw)), 4),
            "cer_synth": round(statistics.mean(grp("synthetic", cers)), 4), "raw_synth": round(statistics.mean(grp("synthetic", raw)), 4),
            "term_hit": round(hits / tot, 4), "clean_ok": clean_ok, "clean_total": len(clean),
            "lat_median": round(statistics.median(lats[cid])), "lat_max": max(lats[cid]),
            "fails": sum(not by[k["id"]][cid]["ok"] for k in cases),
        })
    eligible = [r for r in rows if r["fails"] == 0 and r["lat_median"] <= 4000]
    best = min(eligible, key=lambda r: (r["cer"], r["lat_median"]))["id"] if eligible else None

    combos = []
    for a in ASR_TOP:
        for c in correctors:
            real = [k for k in cases if k["group"] == "real" and k["asr"] == a and k["ref"]]
            vals = [cer(by[k["id"]][c["id"]]["text"], k["ref"]) if by[k["id"]][c["id"]]["ok"] else 1.0 for k in real]
            lat = next(r["lat_median"] for r in rows if r["id"] == c["id"])
            combos.append({"asr": a, "corrector": c["id"], "cer": round(statistics.mean(vals), 4),
                           "est_ms": asr_ms[a] + lat})
    asr_rows = []
    for a in ASR_TOP:
        real = [k for k in cases if k["group"] == "real" and k["asr"] == a and k["ref"]]
        asr_rows.append({"id": a, "ms_mean": asr_ms[a], "raw_cer": round(statistics.mean(cer(k["input"], k["ref"]) for k in real), 4)})

    for k in cases:
        k["outputs"] = {cid: {"ok": o["ok"], "ms": o["ms"], "text": o.get("text"), "error": o.get("error")} for cid, o in by[k["id"]].items()}
    result = {"generated": time.strftime("%Y-%m-%d %H:%M"), "glossary_terms": len([l for l in glossary.splitlines() if l.strip()]),
              "correctors": rows, "asr": asr_rows, "combos": combos, "recommend": best, "cases": cases}
    (HERE / "bench-results.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"\n{'纠错模型':40} {'错字率':>7} {'原始':>6} {'真实':>6} {'合成':>6} {'词命中':>6} {'不误改':>6} {'中位s':>6} {'最大s':>6} 失败")
    for r in sorted(rows, key=lambda r: r["cer"]):
        print(f"{r['id']:40} {r['cer']*100:6.1f}% {r['raw_cer']*100:5.1f}% {r['cer_real']*100:5.1f}% {r['cer_synth']*100:5.1f}% "
              f"{r['term_hit']*100:5.0f}% {r['clean_ok']}/{r['clean_total']:>4} {r['lat_median']/1000:6.2f} {r['lat_max']/1000:6.2f} {r['fails']}")
    print("\n推荐（零失败、中位耗时≤4s、错字率最低）:", best)


if __name__ == "__main__":
    main()
