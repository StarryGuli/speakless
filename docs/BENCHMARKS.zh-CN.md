# 测试报告

下面的数字都来自作者做的小规模、非正式测试，只能作参考，不是排行榜。脚本在 [`tests/siliconflow/`](../tests/siliconflow)，汇总结果在 [`tests/results/`](../tests/results)。**不公开任何录音和转写原文。**

## 一、哪个 ASR 最接近 Typeless？（60 条真实录音）

**方法**：从作者自己的 Typeless 本机库里随机抽 60 条纯听写录音（共 868 秒）。**参照文本是 Typeless 自己的整理结果**，所以分数衡量的是"和 Typeless 输出有多像"，不是"和说话内容一致"（Typeless 本身会改写、删减）。指标是去掉标点和空格后的字错率（CER），越低越接近。"整理后"指转写再经过 Speakless 默认整理提示词（`DeepSeek-V4.1-Flash`）。

只有 60 条，一条录音就能让分数动 1–2 个点：差距小于约 2 个点可视为噪声。

### OpenRouter 专用语音转文字模型（取"加/不加语言和术语提示"里更好的一个）

| 模型 | 原始 | 整理后 | 中位耗时 | 868 秒花费 |
|---|---|---|---|---|
| `microsoft/mai-transcribe-1.5` | 23.1% | 20.3% | 3.3 s | $0.090 |
| `fish-audio/transcribe-1` | 25.6% | 21.1% | 3.4 s | $0.090 |
| `microsoft/mai-transcribe-2` | 23.7% | 21.5% | 2.5 s | $0.025 |
| `qwen/qwen3-asr-0.6b` | 26.6% | 22.8% | 2.7 s | $0.003 |
| `elevenlabs/scribe-v2` | 29.3% | 23.6% | 2.8 s | $0.053 |
| `mistralai/voxtral-mini-transcribe` | 33.0% | 23.7% | 2.9 s | $0.042 |
| `openai/gpt-4o-mini-transcribe` | 28.9% | 24.5% | 2.9 s | $0.025 |
| `openai/gpt-transcribe` | 27.0% | 24.8% | 2.7 s | $0.067 |
| `openai/whisper-1` | 35.0% | 26.4% | 4.1 s | $0.090 |
| `google/chirp-3` | 30.9% | 26.9% | 4.3 s | $0.239 |
| `deepgram/nova-3` | 33.7% | 30.6% | 2.7 s | $0.062 |
| `openai/whisper-large-v3` | 43.2% | 31.3% | 4.1 s | $0.007 |
| `x-ai/grok-stt-1.0` | 34.8% | 31.6% | 2.6 s | $0.024 |
| `openai/whisper-large-v3-turbo` | 40.2% | 36.4% | 3.9 s | $0.004 |
| `openai/gpt-4o-transcribe` | 38.8% | 38.9% | 3.1 s | $0.043 |
| `nvidia/parakeet-tdt-0.6b-v3` | 133.8% | 134.4% | 2.7 s | $0.017 |

备注：`nvidia/parakeet-tdt-0.6b-v3`（只支持欧洲语言）和不带语言提示的 `deepgram/nova-3` 在中文上失败（CER 超过 100%）。`microsoft/mai-transcribe-2` 有一轮出现 2 条 HTTP 429。传 `language=zh` 和术语提示，对多数模型的影响约 1 个点或更小。

### 硅基流动模型

| 模型 | 原始 | 整理后 | 识别中位耗时 | 失败 |
|---|---|---|---|---|
| `Qwen/Qwen3-ASR-1.7B` | 25.4% | 22.7% | 3.2 s | 0 |
| `XingChenAGI/XingChenASR-V3.2-Ultra` | 32.4% | 30.8% | 5.5 s | 0 |
| `Qwen/Qwen3-Omni-30B-A3B-Instruct` | 28.8% | 24.9% | 6.9 s | 2 |

## 二、更早的硅基流动测试（合成句和短录音）

2026-10-30 用几条真实录音加 16 条手写的中英夹杂句（有已知参照和 41 个术语的术语表）测的。这里的参照是想表达的原文，不是 Typeless 的输出。

| 识别模型 | 原始 CER | 平均耗时 |
|---|---|---|
| `Qwen/Qwen3-ASR-1.7B` | 9.7% | 0.9 s |
| `XingChenAGI/XingChenASR-V3.2-Ultra` | 14.3% | 3.2 s |
| `Qwen/Qwen3-Omni-30B-A3B-Instruct` | 19.8% | 1.4 s |

| 整理模型 | 整理后 CER | 术语命中 | 中位耗时 |
|---|---|---|---|
| `deepseek-ai/DeepSeek-V4.1-Flash` | 3.0% | 94% | 1.3 s |
| `Qwen/Qwen3.5-122B-A10B` | 3.4% | 94% | 1.7 s |
| `Qwen/Qwen3.5-35B-A3B` | 4.0% | 89% | 3.1 s |
| `deepseek-ai/DeepSeek-V3.2` | 4.1% | 90% | 6.7 s |
| `Qwen/Qwen3-30B-A3B-Instruct-2507` | 5.8% | 89% | 1.7 s |

其余测过的整理模型更慢或更不稳定（`Qwen3.8-27B`、`GLM-5.3-Flash`、`Step-3.5-Flash`）。完整数据见 [`tests/siliconflow/bench-results.json`](../tests/siliconflow/bench-results.json)（仅汇总）。

## 三、和 Typeless 的差距由什么组成

把最差的几条并排看：

- **主要是风格，不只是识别。** Typeless 会改写：删掉口语铺垫、合并重复、调整语序，常常自动分段、列编号。Speakless 更贴近说话原文。字级 CER 会把这些全部算作差异。
- **确实还有识别错误**，集中在技术名词和品牌名（模型名被听成别的词、英文缩写被拆开）。术语表能缓解但不能消除。
- **换 ASR 模型收益有限**：上表里最好的一个，整理后也只比当前默认好约 2 个点。

## 四、提示词实验：让它改写得更多

假设：放宽"尽量保留原话措辞"的规则，输出会更接近 Typeless。变体 `v1` 让整理模型写成通顺书面文字，而不是近乎逐字的转写。用缓存的 `Qwen3-ASR-1.7B` 转写，前 40 条作调优集，后 20 条作留出集：

| 提示词 | CER（调优集） | CER（留出集） | 成对评审（谁更像 Typeless 风格） |
|---|---|---|---|
| 当前默认 | 20.0% | 26.3% | **胜 36** |
| `v1` 多改写 | 22.4% | 24.3% | 胜 17（平 6） |

调优集变差，留出集略好，LLM 评审（同一模型家族，参考价值有限）约 2:1 偏向当前提示词。**没有明确收益，所以默认提示词不变。**

## 复现

```bash
export SILICONFLOW_API_KEY=...  OPENROUTER_API_KEY=...        # 用你自己的 key
python3 tests/siliconflow/make_typeless_sample.py 60           # 需要你本机有 Typeless 库
python3 tests/siliconflow/tl_eval.py 60                        # 硅基流动 ASR 对照 Typeless
python3 tests/siliconflow/stt_or.py 60                         # OpenRouter 转写模型对照 Typeless
python3 tests/siliconflow/judge.py v0 v1   # compares two prompt variants of your own (prompt files are not shipped)
```
