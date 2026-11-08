#!/usr/bin/env python3
"""成对评审：和 Typeless 的整理结果相比，A、B 哪个在措辞、结构、干净程度上更接近？（模型随机换位，防位置偏差）
用法：SILICONFLOW_API_KEY=... python3 judge.py v0 v1   读 /tmp/prompt_iter_out.json"""
import json, os, random, sys
from concurrent.futures import ThreadPoolExecutor
import server
KEY = os.environ["SILICONFLOW_API_KEY"]; a, b = sys.argv[1:3]
o = json.load(open("/tmp/prompt_iter_out.json")); data = json.load(open("tl-results.json"))["Qwen/Qwen3-ASR-1.7B"]
ref = {x["id"]: (x["ref"], x["raw"]) for x in data}
random.seed(3); jobs = []
for xa, xb in zip(o[a], o[b]):
    if not xa["out"] or not xb["out"]: continue
    sw = random.random() < .5; jobs.append((xa["id"], xa["out"], xb["out"], sw))
def judge(j):
    i, ta, tb, sw = j; A, B = (tb, ta) if sw else (ta, tb)
    msg = (f"参考文本（目标风格）：\n{ref[i][0]}\n\n口述原文（ASR）：\n{ref[i][1]}\n\n候选A：\n{A}\n\n候选B：\n{B}\n\n"
           "哪个候选在措辞、句子结构、分段和干净程度上更接近参考文本，同时没有丢失口述里的事实和要求？只回答一个字母：A、B，或 T（差不多）。")
    try:
        r = server.post_json("/chat/completions", {"model": "deepseek-ai/DeepSeek-V4.1-Flash", "messages": [{"role": "user", "content": msg}], "temperature": 0, "max_tokens": 5, "enable_thinking": False}, KEY, 60)
        x = (r["choices"][0]["message"]["content"] or "").strip().upper()[:1]
    except Exception: return "?"
    if x == "T": return "T"
    if x not in "AB": return "?"
    return (b if (x == "A") == sw else a) if x in "AB" else "?"
with ThreadPoolExecutor(max_workers=6) as ex: res = list(ex.map(judge, jobs))
print(f"{len(jobs)} 对：{a} 胜 {res.count(a)}，{b} 胜 {res.count(b)}，差不多 {res.count('T')}，无效 {res.count('?')}")
