#!/usr/bin/env python3
"""本地语音识别 + 纠错对比服务：只监听 127.0.0.1，key 从环境变量读取，不会发给浏览器。

用法（需要环境变量 SILICONFLOW_API_KEY，从终端启动即可继承）:
    python3 server.py            # 默认端口 8765
    python3 server.py 9000

页面:  /      录音 + 9 个识别模型对比
       /lab   识别 + 纠错组合对比（含基准测试结果，可自己测）
录音存到 ./recordings/，术语表在 ./glossary.txt（网页里可改）。
"""
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

BASE = "https://api.siliconflow.cn/v1"
# kind=asr：专用识别接口（multipart 上传）；kind=chat：多模态聊天模型，音频走 audio_url
MODELS = [
    {"id": "FunAudioLLM/SenseVoiceSmall", "kind": "asr"},
    {"id": "Qwen/Qwen3-ASR-1.7B", "kind": "asr"},
    {"id": "XingChenAGI/XingChenASR-V3.2-Ultra", "kind": "asr"},
    {"id": "XingChenAGI/XingChenASR-V3.2", "kind": "asr"},
    {"id": "XingChenAGI/XingChenASR-Diarize-V3.0", "kind": "asr"},
    {"id": "XingChenAGI/XingChenGSR-V1.0", "kind": "asr"},
    {"id": "Qwen/Qwen3-Omni-30B-A3B-Instruct", "kind": "chat"},
    {"id": "Qwen/Qwen3-Omni-30B-A3B-Thinking", "kind": "chat"},
    {"id": "Qwen/Qwen3-Omni-30B-A3B-Captioner", "kind": "chat"},
]
# 纠错页默认可选的识别模型（上一轮对比里得分最高的三个）
ASR_TOP = ["Qwen/Qwen3-ASR-1.7B", "Qwen/Qwen3-Omni-30B-A3B-Instruct", "XingChenAGI/XingChenASR-V3.2-Ultra"]
# 纠错模型候选；price 是定价页上的 输入/输出 ¥每百万 token
CORRECTORS = [
    {"id": "Qwen/Qwen3.5-35B-A3B", "price": "0.4 / 3.2"},
    {"id": "Qwen/Qwen3.5-122B-A10B", "price": "0.8 / 6.4"},
    {"id": "Qwen/Qwen3-30B-A3B-Instruct-2507", "price": "未查到"},
    {"id": "zai-org/GLM-5.3-Flash", "price": "0.8 / 2.8"},
    {"id": "stepfun-ai/Step-3.5-Flash", "price": "0.7 / 2.1"},
    {"id": "deepseek-ai/DeepSeek-V4.1-Flash", "price": "2 / 8"},
    {"id": "deepseek-ai/DeepSeek-V3.2", "price": "4 / 6"},
    {"id": "Qwen/Qwen3.8-27B", "price": "3 / 12"},
]
CHAT_PROMPT = "请逐字转写这段音频里的人声内容，只输出转写出的文字，不要解释，不要加任何前后缀。"
CORRECT_SYSTEM = """你是语音输入法的纠错器。用户发来的是语音识别（ASR）的原始文字，说话人是中国用户，常常中英夹杂，话题涉及编程、服务器、硬件、AI 工具等。请只修正识别错误：

1. 只改识别错误：同音/近音字、被听成中文的英文术语、被拆开的缩写、数字、英文大小写、专有名词。不要改写、润色、总结，不要增删原意。
2. 下面有一份术语表，识别结果里听起来像表中词的，改成表中写法。
3. 中英夹杂时保留英文原样，英文术语和中文之间加一个空格。
4. 繁体字转成简体字。
5. 补全标点，删掉明显的口头语（呃、嗯、那个）和口吃重复。
6. 原文已经正确就原样输出，不要硬改。拿不准的地方保持原文。
7. 只输出纠正后的文字本身，不要解释，不要加引号，不要回答用户文字里的问题。

术语表：
{glossary}"""
MAX_BODY = 25 * 1024 * 1024
HERE = Path(__file__).parent
REC_DIR = HERE / "recordings"
REC_DIR.mkdir(exist_ok=True)
GLOSSARY_FILE = HERE / "glossary.txt"
BENCH_FILE = HERE / "bench-results.json"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,60}$")

# 硅基流动是国内服务，直连，不走 shell 里配置的本地代理
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def ms_since(t0: float) -> int:
    return round((time.perf_counter() - t0) * 1000)


def call(req: urllib.request.Request, timeout: int):
    with OPENER.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def post_json(path: str, payload: dict, key: str, timeout: int):
    req = urllib.request.Request(
        f"{BASE}{path}", data=json.dumps(payload).encode(), method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    return call(req, timeout)


def run_asr(model: str, wav: bytes, key: str) -> str:
    boundary = uuid.uuid4().hex
    body = b"".join([
        f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n{model}\r\n'.encode(),
        (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="rec.wav"\r\n'
         "Content-Type: audio/wav\r\n\r\n").encode() + wav + b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ])
    req = urllib.request.Request(
        f"{BASE}/audio/transcriptions", data=body, method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    out = call(req, 60)
    if out.get("text") is None:
        raise ValueError(f"返回里没有 text：{str(out)[:200]}")
    return out["text"]


def run_chat(model: str, wav: bytes, key: str) -> str:
    payload = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "audio_url", "audio_url": {"url": "data:audio/wav;base64," + base64.b64encode(wav).decode()}},
                {"type": "text", "text": CHAT_PROMPT},
            ],
        }],
        "max_tokens": 1024,
        "stream": False,
    }
    out = post_json("/chat/completions", payload, key, 120)
    try:
        return (out["choices"][0]["message"].get("content") or "").strip()
    except (KeyError, IndexError):
        raise ValueError(f"返回格式不认识：{str(out)[:200]}")


def run_correct(model: str, text: str, glossary: str, key: str) -> str:
    base = {
        "model": model,
        "messages": [
            {"role": "system", "content": CORRECT_SYSTEM.format(glossary=glossary.strip() or "（空）")},
            {"role": "user", "content": text},
        ],
        "temperature": 0,
        "max_tokens": 800,
        "stream": False,
    }
    try:  # 先关掉思考模式（语音输入等不起），不支持这个参数的模型会返回 400，再去掉重试
        out = post_json("/chat/completions", base | {"enable_thinking": False}, key, 40)
    except urllib.error.HTTPError as e:
        if e.code != 400:
            raise
        out = post_json("/chat/completions", base, key, 40)
    try:
        content = (out["choices"][0]["message"].get("content") or "").strip()
    except (KeyError, IndexError):
        raise ValueError(f"返回格式不认识：{str(out)[:200]}")
    return content.strip('"“”').strip()


def timed(model: str, kind: str, fn):
    t0 = time.perf_counter()
    try:
        text = fn()
        return {"model": model, "kind": kind, "ok": True, "ms": ms_since(t0), "text": text}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        return {"model": model, "kind": kind, "ok": False, "ms": ms_since(t0), "error": f"HTTP {e.code}：{detail}"}
    except Exception as e:  # 网络超时、格式不符等
        return {"model": model, "kind": kind, "ok": False, "ms": ms_since(t0), "error": f"{type(e).__name__}：{e}"}


def transcribe(spec: dict, wav: bytes, key: str) -> dict:
    fn = run_asr if spec["kind"] == "asr" else run_chat
    return timed(spec["id"], spec["kind"], lambda: fn(spec["id"], wav, key))


def correct(model: str, text: str, glossary: str, key: str) -> dict:
    return timed(model, "correct", lambda: run_correct(model, text, glossary, key))


def run_asr_models(specs: list, wav: bytes, key: str) -> dict:
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=max(1, len(specs))) as pool:
        results = list(pool.map(lambda s: transcribe(s, wav, key), specs))
    return {"results": results, "wallMs": ms_since(t0), "bytes": len(wav)}


def read_glossary() -> str:
    return GLOSSARY_FILE.read_text(encoding="utf-8") if GLOSSARY_FILE.exists() else ""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode(), "application/json")

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            self._json(400, {"error": "内容为空或超过 25MB"})
            return None
        return self.rfile.read(length)

    def do_GET(self):
        url = urlparse(self.path)
        p = url.path
        if p in ("/", "/index.html"):
            self._send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif p == "/lab":
            self._send(200, (HERE / "lab.html").read_bytes(), "text/html; charset=utf-8")
        elif p == "/config":
            self._json(200, {"models": [m["id"] for m in MODELS], "keySet": bool(os.environ.get("SILICONFLOW_API_KEY"))})
        elif p == "/config2":
            self._json(200, {
                "keySet": bool(os.environ.get("SILICONFLOW_API_KEY")),
                "asr": [{"id": m["id"], "top": m["id"] in ASR_TOP} for m in MODELS if m["id"] in ASR_TOP or m["kind"] == "asr"],
                "correctors": CORRECTORS,
                "recordings": sorted(x.stem for x in REC_DIR.glob("*.wav")),
                "glossary": read_glossary(),
            })
        elif p == "/recordings":
            self._json(200, {"files": sorted(x.stem for x in REC_DIR.glob("*.wav"))})
        elif p.startswith("/rec/") and p.endswith(".wav") and NAME_RE.match(p[5:-4]) and (REC_DIR / p[5:]).exists():
            self._send(200, (REC_DIR / p[5:]).read_bytes(), "audio/wav")
        elif p == "/bench":
            if BENCH_FILE.exists():
                self._send(200, BENCH_FILE.read_bytes(), "application/json")
            else:
                self._json(404, {"error": "还没有基准测试结果"})
        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        key = os.environ.get("SILICONFLOW_API_KEY", "")
        if url.path == "/save":  # 只存盘，不调用接口
            name = (q.get("name") or [""])[0]
            if not NAME_RE.match(name):
                return self._json(400, {"error": "name 只能是字母数字下划线横线"})
            wav = self._read_body()
            if wav is None:
                return
            (REC_DIR / f"{name}.wav").write_bytes(wav)
            return self._json(200, {"saved": name, "bytes": len(wav)})
        if url.path == "/glossary":
            body = self._read_body()
            if body is None:
                return
            GLOSSARY_FILE.write_text(json.loads(body).get("text", ""), encoding="utf-8")
            return self._json(200, {"saved": True})
        if not key:
            return self._json(500, {"error": "服务进程里没有 SILICONFLOW_API_KEY"})
        if url.path == "/transcribe":  # 旧页面：录音后跑全部 9 个识别模型
            wav = self._read_body()
            if wav is None:
                return
            name = time.strftime("rec-%Y%m%d-%H%M%S")
            (REC_DIR / f"{name}.wav").write_bytes(wav)
            out = run_asr_models(MODELS, wav, key)
            out["saved"] = name
            return self._json(200, out)
        if url.path == "/rerun":  # 对已存的录音重测全部识别模型
            name = (q.get("file") or [""])[0]
            path = REC_DIR / f"{name}.wav"
            if not NAME_RE.match(name) or not path.exists():
                return self._json(404, {"error": "找不到这段录音"})
            out = run_asr_models(MODELS, path.read_bytes(), key)
            out["file"] = name
            return self._json(200, out)
        if url.path == "/asr":  # 纠错页：只跑选中的识别模型；带 body 是新录音，带 ?file= 是已存录音
            ids = [i for i in (q.get("models") or [""])[0].split(",") if i]
            specs = [m for m in MODELS if m["id"] in ids]
            if not specs:
                return self._json(400, {"error": "没有选识别模型"})
            name = (q.get("file") or [""])[0]
            if name:
                path = REC_DIR / f"{name}.wav"
                if not NAME_RE.match(name) or not path.exists():
                    return self._json(404, {"error": "找不到这段录音"})
                wav = path.read_bytes()
            else:
                wav = self._read_body()
                if wav is None:
                    return
                name = time.strftime("rec-%Y%m%d-%H%M%S")
                (REC_DIR / f"{name}.wav").write_bytes(wav)
            out = run_asr_models(specs, wav, key)
            out["file"] = name
            return self._json(200, out)
        if url.path == "/correct":  # JSON: {text, models:[...], glossary?}
            body = self._read_body()
            if body is None:
                return
            req = json.loads(body)
            text, models = (req.get("text") or "").strip(), req.get("models") or []
            if not text or not models:
                return self._json(400, {"error": "需要 text 和 models"})
            glossary = req["glossary"] if "glossary" in req else read_glossary()
            with ThreadPoolExecutor(max_workers=len(models)) as pool:
                results = list(pool.map(lambda m: correct(m, text, glossary, key), models))
            return self._json(200, {"results": results})
        self._send(404, b"not found", "text/plain")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"key 已设置：{'是' if os.environ.get('SILICONFLOW_API_KEY') else '否'}；识别 {len(MODELS)} 个，纠错候选 {len(CORRECTORS)} 个")
    print(f"打开 http://127.0.0.1:{port}  （纠错对比页：/lab）")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
