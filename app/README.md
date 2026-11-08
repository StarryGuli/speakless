# Speakless

macOS 语音听写软件：按一下快捷键说话，再按一下，识别 + 纠错后的文字直接写进光标处。
界面照着 Typeless 做（Home / History / Dictionary / Settings），**识别模型和纠错模型都能在 Settings → Models 里随时切换**（硅基流动）。

## 编译和运行

只需要 Command Line Tools，不需要完整 Xcode：

```bash
cd app && ./build.sh      # 生成 build/Speakless.app
open build/Speakless.app
./build.sh --install   # 或者装进 /Applications，Spotlight 里就能搜到
```

## 第一次使用

1. Settings → Models：粘贴硅基流动 API key，或点 "Import from ~/.zshrc"，再点 Test connection。
2. Home 右侧 Setup：依次允许 Microphone、Input Monitoring、Accessibility。
3. 系统设置 → 键盘 → "按 🌐 键时" 改成 "不执行任何操作"，否则按 Fn 会弹出情感符号面板。
4. 按 Fn 说话，再按一次结束。

> 签名：`build.sh` 会优先用钥匙串里的本地证书 "Speakless Local Signing"，这样重新编译后系统权限不会丢（第一次换证书后要重新授权一次）。
> 没有这张证书时退回 ad-hoc 签名，每次编译后都要重新授权。

## 快捷键

Settings → Shortcuts → Dictate：点输入框，把想用的键**同时按下去再松开**，软件会自动识别。
- 单个修饰键（比如只按 Fn）：按一下再松开算一次。
- 2～3 个键组合（比如 Fn+Space、Right Cmd+Right Option）：这几个键同时按住时触发。组合里的普通键需要「辅助功能」权限才能不被打进当前 App。
- 录音或处理中按 **Esc** 可以中断这次听写（什么都不会粘贴）；没在听写时 Esc 照常交给当前 App。需要「辅助功能」权限才能拦下这个键，否则 Esc 也会同时传给前台 App。
- 普通字母键不能单独当快捷键，必须搭配 Fn / Ctrl / Option / Shift / Cmd；功能键 F1–F20 可以单独用。
- 录入时单按 Esc 取消。

## 流程

按键 → 录音（16kHz 单声道）→ 识别模型 → 纠错模型（词典里的词作为提示；超时则直接用识别原文）→ 剪贴板 + ⌘V 写入光标处（随后还原剪贴板）→ 记入历史。

## 平台和模型（Settings → Models）

- **平台**：可以加任意多个（内置了硅基流动、OpenAI、Groq、DeepSeek、Kimi、智谱、阿里百炼、OpenRouter、Ollama、LM Studio 的预设，也可以加「自定义」：任何兼容 OpenAI 接口的服务）。每个平台有自己的地址、key、认证方式、网络方式（直连/系统代理）、接口路径和额外请求头。
- **语音识别**和**纠错**各自选「平台 + 模型」，可以不是同一家。
- **参数**：Auto 由平台和模型推出来，并且把实际会发送的参数全部显示出来；Manual 可以逐项修改（识别方式、语言提示、温度、最大输出、思考参数、超时、价格等）。从 Auto 切到 Manual 时，先把 Auto 的值抄过来，再改。
- 每个平台的 key 单独存在 `~/Library/Application Support/Speakless/keys/<平台id>`（权限 0600）。
- 只有硅基流动上的模型在本项目里实测过；其它平台的预设和建议模型没有测试过。

## 数据在哪

`~/Library/Application Support/Speakless/`：`settings.json`、`history.json`、`dictionary.json`、`stats.json`、`audio/`（历史录音）、`api-key`（权限 0600）。
都只在本机，不进 git。声音只会发给硅基流动做识别和纠错。

## 命令行自测

```bash
zsh -ic './build/Speakless.app/Contents/MacOS/Speakless --selftest 某段.wav'
```

## 还没做（界面上标了 Soon）

Translate、Ask anything、界面语言切换、自动收录词典（Auto-added）。
