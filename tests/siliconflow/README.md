# SiliconFlow 测试项

Speakless 当前唯一实测过的模型平台是硅基流动（SiliconFlow）。这个目录是围绕它的测试和选型材料：

- `bench.py` / `server.py` / `lab.html` / `index.html`：语音识别（ASR）模型和纠错模型的对比评测网页与脚本
- `glossary.txt`：评测用的术语表
- `bench-results.json`：上一次评测的结果
- `recordings/`：自己录的测试音频（个人声音数据，已在 .gitignore 里，不入库）

App 里和硅基流动相关的开发自测开关（在 `app/` 里编译后用 `open -a /Applications/Speakless.app --args …` 运行）：

- `--selftest <wav>`：一段录音 → 识别 → 纠错，打印结果
- `--provider-test <wav>`：按当前平台设置测一遍
- `--correct-test <文件>`：每行 `软件名|识别文字`，只测纠错提示词
- `--payload-demo`：看实际发给平台的请求内容
