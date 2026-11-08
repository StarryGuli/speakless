#!/usr/bin/env python3
"""生成 README 用的 SVG（hero / pipeline / bench），英文和中文各一份。python3 build.py"""
import json, os
from xml.sax.saxutils import escape as X
HERE = os.path.dirname(os.path.abspath(__file__))
PAPER, INK, MUT, BLUE, GREEN, LINE = "#F3F1EC", "#161618", "#6E6D72", "#3B5BF5", "#2E9C74", "#D9D6CE"
SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'PingFang SC', 'Helvetica Neue', sans-serif"
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"

def svg(w, h, title, desc, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" aria-labelledby="t d">'
            f'<title id="t">{X(title)}</title><desc id="d">{X(desc)}</desc>'
            f'<rect x="1" y="1" width="{w-2}" height="{h-2}" rx="28" fill="{PAPER}" stroke="{LINE}" stroke-width="2"/>{body}</svg>')

def t(x, y, s, size, fill=INK, weight=400, font=SANS, anchor="start", ls=0, extra=""):
    return f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}" letter-spacing="{ls}" {extra}>{X(s)}</text>'

def chip(x, y, s, w, fill="none", stroke=INK, color=INK, size=20):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="38" rx="19" fill="{fill}" stroke="{stroke}" stroke-width="2"/>'
            + t(x + w / 2, y + 26, s, size, color, 600, anchor="middle"))

L = {
 "en": dict(eyebrow="macOS DICTATION  ·  BRING YOUR OWN MODEL", tag1="Press a key, speak.", tag2="Clean text lands at your cursor.",
            chips=[("Your own API key", 214), ("Local models", 178), ("Ask Anything", 178)],
            raw="um so I think I can't make it on friday can you send me the file", clean1="I can't make it on Friday.", clean2="Can you send me the file?",
            rawl="WHAT YOU SAID", cleanl="WHAT LANDS",
            pt=("Record", "hotkey · streaming"), pa=("Recognize", "your key or your server"), pc=("Clean up", "LLM · glossary · context"), pw=("Write", "at the cursor"),
            ctx="CONTEXT — every item optional", cchips=[("App", 80), ("Window title", 160), ("Page URL", 130), ("Selection", 130), ("Text around cursor", 230), ("Visible text", 150)],
            bt="Closeness to Typeless's output", bs="lower is closer · 60 real recordings, after cleanup", bf="Reference = Typeless's own refined text. Differences under ~2 points are noise.", dflt="current default"),
 "zh": dict(eyebrow="macOS 语音听写  ·  自带模型", tag1="按一下，说话，", tag2="干净的文字落在光标处。",
            chips=[("自带 API key", 170), ("本地模型", 150), ("Ask Anything", 178)],
            raw="呃那个我就是想说周五我可能去不了你把资料发我一下", clean1="周五我可能去不了，", clean2="你把资料发我一下。",
            rawl="你说的", cleanl="写出来的",
            pt=("录音", "快捷键 · 边说边识别"), pa=("识别", "你的 key 或你的服务器"), pc=("整理", "LLM · 术语表 · 上下文"), pw=("写入", "光标处"),
            ctx="上下文——每一项都可关闭", cchips=[("当前 App", 120), ("窗口标题", 130), ("网页地址", 130), ("选中文字", 130), ("光标前后文", 150), ("屏幕可见文字", 170)],
            bt="和 Typeless 输出的接近程度", bs="越低越接近 · 60 条真实录音 · 整理后", bf="参照 = Typeless 自己的整理结果；差距小于约 2 个点可视为噪声。", dflt="当前默认"),
}

def hero(lang):
    s = L[lang]; b = ""
    b += t(64, 78, s["eyebrow"], 20, BLUE, 600, MONO, ls=1.5)
    b += t(60, 214, "Speakless", 132, INK, 700, ls=-4)
    b += t(64, 272, s["tag1"], 34, INK, 600) + t(64, 316, s["tag2"], 34, INK, 600)
    x = 64
    for name, w in s["chips"]:
        b += chip(x, 340, name, w); x += w + 12
    # card
    b += f'<rect x="700" y="52" width="440" height="304" rx="22" fill="#FFFFFF" stroke="{LINE}" stroke-width="2"/>'
    b += f'<circle cx="730" cy="84" r="6" fill="#FF5F57"/><circle cx="750" cy="84" r="6" fill="#FEBC2E"/><circle cx="770" cy="84" r="6" fill="#28C840"/>'
    b += f'<rect x="800" y="70" width="300" height="52" rx="26" fill="{INK}"/>'
    hs = [10, 18, 28, 16, 32, 22, 12, 26, 18, 30, 14, 22, 10]
    for i, hh in enumerate(hs):
        b += f'<rect x="{826 + i * 11}" y="{96 - hh/2}" width="5" height="{hh}" rx="2.5" fill="#FFFFFF"/>'
    b += t(990, 103, "Listening" if lang == "en" else "正在听", 22, "#FFFFFF", 600, anchor="start")
    b += t(730, 168, s["rawl"], 16, MUT, 600, MONO, ls=1.5)
    if lang == "en":
        b += t(730, 196, "um so I think I can't make it on", 20, MUT) + t(730, 222, "friday can you send me the file", 20, MUT)
    else:
        b += t(730, 196, "呃那个我就是想说周五我可能去不了", 20, MUT) + t(730, 222, "你把资料发我一下", 20, MUT)
    b += f'<path d="M 730 242 L 1110 242" stroke="{LINE}" stroke-width="2" stroke-dasharray="4 6"/>'
    b += t(730, 276, s["cleanl"], 16, GREEN, 600, MONO, ls=1.5)
    b += t(730, 306, s["clean1"], 26, INK, 700) + t(730, 338, s["clean2"], 26, INK, 700)
    return svg(1200, 400, "Speakless", "Native macOS dictation: press a key, speak, cleaned-up text lands at the cursor.", b)

def pipeline(lang):
    s = L[lang]; b = ""
    nodes = [s["pt"], s["pa"], s["pc"], s["pw"]]
    xs = [56, 340, 624, 908]
    for i, ((n, sub), x) in enumerate(zip(nodes, xs)):
        hot = i == 2
        b += f'<rect x="{x}" y="46" width="236" height="104" rx="20" fill="{BLUE if hot else "#FFFFFF"}" stroke="{BLUE if hot else INK}" stroke-width="2.5"/>'
        b += t(x + 118, 92, n, 32, "#FFFFFF" if hot else INK, 700, anchor="middle")
        b += t(x + 118, 126, sub, 18, "#DCE3FF" if hot else MUT, 500, anchor="middle")
        if i < 3:
            b += f'<path d="M {x+244} 98 L {xs[i+1]-10} 98" stroke="{INK}" stroke-width="3" stroke-linecap="round"/><path d="M {xs[i+1]-22} 88 L {xs[i+1]-8} 98 L {xs[i+1]-22} 108" fill="none" stroke="{INK}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>'
    b += f'<path d="M 742 150 L 742 188" stroke="{BLUE}" stroke-width="2.5" stroke-dasharray="3 7" stroke-linecap="round"/>'
    b += t(56, 218, s["ctx"], 18, BLUE, 600, MONO, ls=1.2)
    x = 56
    for name, w in s["cchips"]:
        b += chip(x, 236, name, w, size=19); x += w + 12
    return svg(1200, 310, "How Speakless works", "Record, recognize, clean up with context and glossary, write at the cursor.", b)

def bench(lang):
    s = L[lang]
    d = json.load(open(os.path.join(HERE, "../../tests/results/openrouter-stt-vs-typeless.json")))["rows"]
    sf = json.load(open(os.path.join(HERE, "../../tests/results/siliconflow-asr-vs-typeless.json")))["rows"]
    best = {}
    for r in d:
        if r["model"] not in best or r["cer_out"] < best[r["model"]]["cer_out"]: best[r["model"]] = r
    rows = [(k, v["cer_out"], False) for k, v in best.items()] + [("Qwen/Qwen3-ASR-1.7B", next(r for r in sf if r["model"] == "Qwen/Qwen3-ASR-1.7B")["cer_out"], True)]
    rows = sorted(rows, key=lambda r: r[1])[:7]
    if not any(r[2] for r in rows): rows[-1] = ("Qwen/Qwen3-ASR-1.7B", rows[-1][1], True)
    rows = sorted(rows, key=lambda r: r[1])
    b = t(56, 70, s["bt"], 36, INK, 700) + t(56, 104, s["bs"], 20, MUT, 500)
    x0, wmax, y = 400, 640, 140
    for name, v, dflt in rows:
        b += t(x0 - 16, y + 27, name.split("/")[-1] if not dflt else "Qwen3-ASR-1.7B", 20, INK, 700 if dflt else 500, anchor="end")
        w = v / 0.40 * wmax
        b += f'<rect x="{x0}" y="{y}" width="{w:.0f}" height="36" rx="8" fill="{BLUE if dflt else "#CFCBC0"}"/>'
        b += t(x0 + w + 12, y + 27, f"{v*100:.1f}%", 20, INK, 700)
        if dflt: b += t(x0 + w + 80, y + 27, s["dflt"], 18, BLUE, 600)
        y += 50
    b += t(56, y + 24, s["bf"], 18, MUT, 500)
    return svg(1200, y + 56, "Benchmark vs Typeless", "Bar chart of cleanup-stage character error rate versus Typeless output for several speech recognition models.", b)

for lang, suf in (("en", ""), ("zh", ".zh-CN")):
    for name, fn in (("hero", hero), ("pipeline", pipeline), ("bench", bench)):
        open(os.path.join(HERE, f"{name}{suf}.svg"), "w", encoding="utf-8").write(fn(lang))
print("ok")
