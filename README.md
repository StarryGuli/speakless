# Speakless

**中文** · [English](#english)

macOS 原生语音听写：按一下快捷键说话，再按一下，识别并纠错后的文字直接写进光标处。
Swift / SwiftUI 编写，不依赖 Xcode，只要 Command Line Tools 就能编译。

## 特点

- **模型自己选**：识别模型和纠错模型都能在 Settings → Models 里切换。支持硅基流动等 OpenAI 兼容接口，也支持**自建/本机服务**（如你自己的显卡机器上的 ASR、Ollama）。
- **本机模型友好**：可选的"状态与预热"接口，开始录音时就让自建服务提前加载模型；边说边识别（流式分段），说完即出字。该接口是非标准的，默认关闭，仅在你自己的服务支持时手动打开。
- **中文优先**：纠错提示词和术语表针对中文口述、中英混说调校，`tests/siliconflow/` 里有可复现的小型评测脚本。
- **上下文感知**：可读取当前 App、窗口标题、网页地址、选中文字、光标前后文，让纠错更贴合场景。全部可逐项关闭，也可指定"不读取的 App"。
- **Ask Anything**：用另一个快捷键提问，答案显示在浮窗里，不改你的文字；可选联网搜索并给出引用。录音中途按提问键即可切换到提问。
- **历史与耗时**：每条记录显示各阶段耗时、使用的服务商与模型、本地或在线。
- 个人词典、自动学习你的改词、全局快捷键（可自定义组合键）。

## 编译和运行

```bash
cd app
./build.sh            # 生成 build/Speakless.app
./build.sh --install  # 或装进 /Applications
```

首次使用：Settings → Models 填入你自己的 API key（密钥只保存在本机），再按提示授予麦克风、输入监控、辅助功能权限。
签名：`build.sh` 优先使用钥匙串里名为 "Speakless Local Signing" 的本地证书，没有则退回 ad-hoc 签名（每次编译后需重新授权）。

## 隐私

- 项目没有自己的服务器，不收集任何数据。
- 音频和文字只发送到**你在设置里配置的**识别/纠错服务。
- 上下文（窗口标题、屏幕文字等）会随纠错请求一起发给你配置的模型服务商；不想发送请在 Settings → Context 里关闭。
- 联网搜索（Ask Anything）会把检索关键词发送给 Bing / DuckDuckGo。

## 状态

早期版本，仅在 macOS 上测试。欢迎 issue 与 PR。

## 许可

MIT，见 [LICENSE](LICENSE)。

---

## English

Speakless is a native macOS dictation app: press a hotkey, speak, press again, and the transcribed, cleaned-up text is typed at your cursor. Written in Swift/SwiftUI; builds with just the Command Line Tools.

**Highlights**

- **Bring your own models.** Swap ASR and cleanup models in Settings → Models. Works with OpenAI-compatible APIs such as SiliconFlow, and with self-hosted or local servers.
- **Friendly to local models.** An opt-in "status & warm-up" option asks your own server to load its model as soon as you start recording; streaming segments make text appear right after you stop. This endpoint is non-standard, so it is off by default.
- **Chinese-first.** Prompts and glossary are tuned for Chinese and mixed Chinese/English dictation; a small reproducible benchmark lives in `tests/siliconflow/`.
- **Context-aware.** Optionally reads the front app, window title, page URL, selected text and text around the cursor. Every item can be switched off, and you can block specific apps.
- **Ask Anything.** A second hotkey asks a question and shows the answer in a floating box instead of editing your text, with optional web search and citations. Press the ask key mid-recording to switch modes.
- **History with timings.** Per-stage latency, provider, model and local/online for every dictation.
- Personal dictionary, auto-learning from your edits, custom hotkeys.

**Build**

```bash
cd app && ./build.sh --install
```

Add your own API key in Settings → Models and grant Microphone, Input Monitoring and Accessibility permissions when prompted.

**Privacy.** No server of our own, no telemetry. Audio and text go only to the providers you configure. Context is sent along with cleanup requests (toggle it off in Settings → Context). Web search sends the query to Bing / DuckDuckGo.

**Status.** Early release, tested on macOS only. Issues and PRs welcome. MIT licensed.
