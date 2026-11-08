# Speakless

**中文** · [English](#english)

macOS 原生语音听写：按一下快捷键说话，再按一下，识别并纠错后的文字直接写进光标处。
Swift / SwiftUI 编写，不依赖 Xcode，只要 Command Line Tools 就能编译。

<p align="center"><img src="docs/demo/dictate.gif" width="49%"> <img src="docs/demo/ask.gif" width="49%"><br><img src="docs/demo/history.gif" width="49%"> <img src="docs/demo/models.gif" width="49%"></p>
<p align="center"><sub>以上为界面模拟演示（HTML 动画，非真实录屏），文字与数据均为示例。</sub></p>

## 特点

- **模型自己选**：识别模型和纠错模型都能在 Settings → Models 里切换。支持硅基流动等 OpenAI 兼容接口，也支持**自建/本机服务**（如你自己的显卡机器上的 ASR、Ollama）。
- **本机模型友好**：可选的"状态与预热"接口，开始录音时就让自建服务提前加载模型；边说边识别（流式分段），说完即出字。该接口是非标准的，默认关闭，仅在你自己的服务支持时手动打开。
- **中文优先**：纠错提示词和术语表针对中文口述、中英混说调校，`tests/siliconflow/` 里有可复现的小型评测脚本。
- **上下文感知**：可读取当前 App、窗口标题、网页地址、选中文字、光标前后文，让纠错更贴合场景。全部可逐项关闭，也可指定"不读取的 App"。
- **Ask Anything**：用另一个快捷键提问，答案显示在浮窗里，不改你的文字；可选联网搜索并给出引用。录音中途按提问键即可切换到提问。
- **历史与耗时**：每条记录显示各阶段耗时、使用的服务商与模型、本地或在线。
- 个人词典、自动学习你的改词、全局快捷键（可自定义组合键）。

## 安装

**方式一：下载安装包**（推荐）。到 [Releases](../../releases) 下载 `Speakless-x.y.z-macos.zip`，解压后拖进「应用程序」。
安装包尚未经苹果公证，第一次打开会被系统拦下：在「应用程序」里**右键 → 打开 → 仍要打开**；或终端执行 `xattr -dr com.apple.quarantine /Applications/Speakless.app`。系统要求 macOS 13 及以上，Apple Silicon 与 Intel 均可（以发布说明为准）。

**方式二：自己编译**（只需 Command Line Tools，不需要完整 Xcode）

```bash
git clone https://github.com/StarryGuli/speakless.git
cd speakless/app
./build.sh --install     # 编译并装进 /Applications
```

## 5 分钟上手

1. 打开 Speakless → **Settings → Models**，选一个平台并填入你自己的 API key（密钥只存本机），点 Test connection。想用自己的服务：新增一个"无需密钥"的平台，填 base URL 即可。
2. 首页右侧 **Setup** 依次授权：麦克风、输入监控、辅助功能。
3. 若用 Fn 当快捷键：系统设置 → 键盘 →「按 🌐 键时」改成「不执行任何操作」。
4. 在任意输入框里**按一下快捷键说话，再按一下结束**，文字会写到光标处。

## 用法

| 想做的事 | 怎么做 |
|---|---|
| 听写 | 默认 Fn（Settings → Shortcuts 里可改成单个修饰键或 2–3 键组合） |
| 提问 | 默认 Fn+Space。答案出现在浮窗里，不改你的文字，可选"Insert at cursor" |
| 听写途中改成提问 | 录音时按提问键，这一段录音就按"提问"处理 |
| 加专有名词 | Dictionary 里手动加；你在听写后改的词会被自动学习 |
| 看每次耗时 | History：每条记录右侧是各阶段耗时、服务商、模型、本地/在线 |

## 平台与模型

| 类型 | 说明 |
|---|---|
| 硅基流动 | 默认的在线平台。默认识别 Qwen3-ASR-1.7B，纠错 DeepSeek-V4.1-Flash（可换） |
| 其他 OpenAI 兼容服务 | 填 base URL + key 即可 |
| 自建 ASR / Ollama | 无需 key，视为"本地模型"，可设保活时间与加载容忍时间 |
| 状态与预热（可选） | 仅当你的服务提供类似 `/health` 与 `/warmup` 的接口时才打开：开始录音就提前让它加载模型。非标准接口，默认关闭 |

## 上下文

纠错和提问时可附带下列信息，全部默认开启、可逐项关闭，也可设置"不读取的 App"：当前 App 与窗口标题、网页标题与地址、输入框类型、选中文字、光标前后文、屏幕可见文字。上下文只作参考，提示词要求模型不得把它写进输出。

## 项目结构

```
app/Sources/Speakless/   应用源码（SwiftUI + AppKit）
app/build.sh             编译并打包成 .app
tests/siliconflow/       模型评测脚本与结果摘要
docs/                    架构、开发说明、更新日志、演示动图
```

详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 和 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)；贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 常见问题

- **按 Fn 弹出表情面板**：见上手第 3 步。
- **每次重新编译后权限丢了**：用本地自签证书 "Speakless Local Signing" 签名，见 DEVELOPMENT.md。
- **⌘+Space 没反应**：那是系统 Spotlight 的快捷键，请给提问换别的组合。
- **自建服务第一次识别很慢**：模型冷启动要加载，打开"状态与预热"可在你开口时提前加载。
- **会不会上传我的数据**：见下方"隐私"。

## 路线图（计划，不承诺时间）

按 App 设定输出风格、翻译模式、选中文字后语音改写、按住说话、词典导入导出、苹果公证的安装包。

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

<sub>The animations above are simulated UI demos (HTML), not real screen recordings; all text and data are samples.</sub>

**Highlights**

- **Bring your own models.** Swap ASR and cleanup models in Settings → Models. Works with OpenAI-compatible APIs such as SiliconFlow, and with self-hosted or local servers.
- **Friendly to local models.** An opt-in "status & warm-up" option asks your own server to load its model as soon as you start recording; streaming segments make text appear right after you stop. This endpoint is non-standard, so it is off by default.
- **Chinese-first.** Prompts and glossary are tuned for Chinese and mixed Chinese/English dictation; a small reproducible benchmark lives in `tests/siliconflow/`.
- **Context-aware.** Optionally reads the front app, window title, page URL, selected text and text around the cursor. Every item can be switched off, and you can block specific apps.
- **Ask Anything.** A second hotkey asks a question and shows the answer in a floating box instead of editing your text, with optional web search and citations. Press the ask key mid-recording to switch modes.
- **History with timings.** Per-stage latency, provider, model and local/online for every dictation.
- Personal dictionary, auto-learning from your edits, custom hotkeys.

**Install.** Download `Speakless-x.y.z-macos.zip` from [Releases](../../releases), unzip, move to Applications. The build is not notarized yet: right-click → Open the first time (or `xattr -dr com.apple.quarantine /Applications/Speakless.app`). Requires macOS 13+. Or build from source (Command Line Tools only):

```bash
git clone https://github.com/StarryGuli/speakless.git
cd speakless/app && ./build.sh --install
```

**Quick start.** Settings → Models: pick a platform and paste your own API key (stored locally) — or add a no-key platform pointing at your own server. Grant Microphone, Input Monitoring and Accessibility. Press the hotkey (default Fn) to start, press again to finish; text lands at the cursor. Default Ask key is Fn+Space; pressing it during a dictation switches that recording to Ask.

**Context** (all on by default, each can be disabled, apps can be blocked): front app and window title, page title/URL, input type, selected text, text around the cursor, visible screen text. The prompt tells the model never to copy it into the output.

**Docs.** [Architecture](docs/ARCHITECTURE.md) · [Development](docs/DEVELOPMENT.md) · [Contributing](CONTRIBUTING.md) · [Changelog](docs/CHANGELOG.md)

**Roadmap (planned, no dates).** Per-app output styles, translation mode, edit-selection by voice, hold-to-talk, dictionary import/export, notarized builds.

**Privacy.** No server of our own, no telemetry. Audio and text go only to the providers you configure. Context is sent along with cleanup requests (toggle it off in Settings → Context). Web search sends the query to Bing / DuckDuckGo.

**Status.** Early release, tested on macOS only. Issues and PRs welcome. MIT licensed.
