#!/usr/bin/env python3
"""从你自己的 Typeless 本机库里随机抽样录音和它的整理结果，写到 /tmp/tl_sample.json（只在本机，不入库）。
用法：python3 make_typeless_sample.py [条数]   —— 需要你本机装有 Typeless。"""
import json, os, random, sqlite3, shutil, sys
base = os.path.expanduser("~/Library/Application Support/Typeless/")
shutil.copy(base + "typeless.db", "/tmp/tl.db")
c = sqlite3.connect("/tmp/tl.db")
rows = c.execute("select id,refined_text,duration,audio_local_path from history_v2 where mode='voice_transcript' and refined_text is not null and length(refined_text)>8 and duration between 3 and 45").fetchall()
rows = [r for r in rows if r[3] and os.path.exists(r[3] if r[3].startswith('/') else base + r[3])]
random.seed(7)
pick = random.sample(rows, min(int(sys.argv[1]) if len(sys.argv) > 1 else 60, len(rows)))
json.dump([{"id": r[0], "ref": r[1], "dur": r[2], "path": r[3] if r[3].startswith('/') else base + r[3], "mode": "voice_transcript"} for r in pick], open("/tmp/tl_sample.json", "w"), ensure_ascii=False)
print(len(pick), "条已写到 /tmp/tl_sample.json")
