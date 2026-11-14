# Benchmarks

All numbers are from small, informal tests run by the author — treat them as indicative, not as a leaderboard. Scripts are in [`tests/siliconflow/`](../tests/siliconflow), aggregate results in [`tests/results/`](../tests/results). **No recordings or transcripts are published.**

## 1. Which ASR is closest to Typeless? (60 real recordings)

**Method.** 60 voice-transcript recordings (868 s) were sampled at random from the author's own Typeless library. The *reference* is the text Typeless itself produced for each recording — so the score measures **similarity to Typeless's output**, not accuracy against what was really said (Typeless also rewrites and condenses). Metric: character error rate (CER) after stripping punctuation and spaces; lower is closer. "After cleanup" runs the transcript through Speakless's default cleanup prompt with `DeepSeek-V4.1-Flash`.

With only 60 clips, one recording moves a score by 1–2 points: differences under ~2 points are noise.

### OpenRouter dedicated speech-to-text models (best of with/without language + term hints)

| Model | Raw | After cleanup | Median latency | Cost for 868 s |
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

Notes: `nvidia/parakeet-tdt-0.6b-v3` (European languages only) and `deepgram/nova-3` without a language hint fail on Chinese (CER above 100%). `microsoft/mai-transcribe-2` returned HTTP 429 for 2 clips in one run. Passing `language=zh` and a glossary hint changed results by about 1 point or less for most models.

### SiliconFlow models

| Model | Raw | After cleanup | Median ASR latency | Failures |
|---|---|---|---|---|
| `Qwen/Qwen3-ASR-1.7B` | 25.4% | 22.7% | 3.2 s | 0 |
| `XingChenAGI/XingChenASR-V3.2-Ultra` | 32.4% | 30.8% | 5.5 s | 0 |
| `Qwen/Qwen3-Omni-30B-A3B-Instruct` | 28.8% | 24.9% | 6.9 s | 2 |

## 2. Earlier SiliconFlow benchmark (synthetic and short real clips)

Run 2026-10-30 on a few real recordings plus 16 hand-written Chinese/English-mixed sentences with known references and a 41-term glossary. Here the reference is the intended text, not Typeless's.

| ASR model | Raw CER | Mean latency |
|---|---|---|
| `Qwen/Qwen3-ASR-1.7B` | 9.7% | 0.9 s |
| `XingChenAGI/XingChenASR-V3.2-Ultra` | 14.3% | 3.2 s |
| `Qwen/Qwen3-Omni-30B-A3B-Instruct` | 19.8% | 1.4 s |

| Cleanup model | CER after cleanup | Glossary terms hit | Median latency |
|---|---|---|---|
| `deepseek-ai/DeepSeek-V4.1-Flash` | 3.0% | 94% | 1.3 s |
| `Qwen/Qwen3.5-122B-A10B` | 3.4% | 94% | 1.7 s |
| `Qwen/Qwen3.5-35B-A3B` | 4.0% | 89% | 3.1 s |
| `deepseek-ai/DeepSeek-V3.2` | 4.1% | 90% | 6.7 s |
| `Qwen/Qwen3-30B-A3B-Instruct-2507` | 5.8% | 89% | 1.7 s |

Other tested cleanup models were slower or less reliable (`Qwen3.8-27B`, `GLM-5.3-Flash`, `Step-3.5-Flash`). Full numbers: [`tests/siliconflow/bench-results.json`](../tests/siliconflow/bench-results.json) (summary only).

## 3. What the gap to Typeless is made of

Reading the worst cases side by side:

- **Style, not just recognition.** Typeless rewrites: it drops filler lead-ins, merges repeated phrases, reorders clauses and often adds paragraphs or numbered lists. Speakless stays closer to what was said. Character-level CER penalises all of that.
- **Real recognition errors still exist**, mostly on technical terms and brand names (a model name heard as another word, an English acronym split up). A glossary helps but does not remove them.
- **Switching ASR models buys little:** the best option above is about 2 points better than the current default after cleanup.

## 4. Prompt experiment: rewrite more

Hypothesis: loosening the "stay close to the original wording" rule would move output toward Typeless. Variant `v1` told the cleanup model to write polished prose instead of a near-verbatim transcript. Cached transcripts from `Qwen3-ASR-1.7B`, first 40 clips as tuning set, last 20 as hold-out:

| Prompt | CER (tuning) | CER (hold-out) | Pairwise judge vs Typeless style |
|---|---|---|---|
| current default | 20.0% | 26.3% | **wins 36** |
| `v1` rewrite more | 22.4% | 24.3% | wins 17 (6 ties) |

The tuning set got worse, the hold-out got slightly better, and an LLM judge (same model family, so take with salt) preferred the current prompt about 2 to 1. **No clear win, so the default prompt is unchanged.**

## Reproducing

```bash
export SILICONFLOW_API_KEY=...  OPENROUTER_API_KEY=...        # your own keys
python3 tests/siliconflow/make_typeless_sample.py 60           # needs your own local Typeless library
python3 tests/siliconflow/tl_eval.py 60                        # SiliconFlow ASR vs Typeless
python3 tests/siliconflow/stt_or.py 60                         # OpenRouter STT models vs Typeless
python3 tests/siliconflow/judge.py v0 v1   # compares two prompt variants of your own (prompt files are not shipped)
```
