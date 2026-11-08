# Development

## Build and run
```bash
cd app
swift build            # compile check
./build.sh             # produces build/Speakless.app
./build.sh --install   # also copies it into /Applications
```

## Permissions
Grant Microphone, Input Monitoring and Accessibility to the app when prompted. With ad-hoc signing macOS forgets the grants after every rebuild. To avoid that, create a self-signed code-signing certificate named **Speakless Local Signing** in Keychain Access; `build.sh` uses it automatically.

System Settings → Keyboard → "Press 🌐 key to" should be "Do nothing" if you use Fn as a hotkey. ⌘+Space is Spotlight's shortcut; pick another combo for Ask.

## Debugging
- Recorder log: `~/Library/Application Support/Speakless/recorder.log` (also shown in Settings → Audio).
- Context capture self-test: `build/Speakless.app/Contents/MacOS/Speakless --context-test /tmp/out.txt [selectSubstring] [bundleId]` — waits 6 s, captures context from the chosen app, and writes the results of a few model calls.

## Benchmark
`tests/siliconflow/` compares ASR and corrector models on a small Chinese / mixed-language set with a glossary.
```bash
export SILICONFLOW_API_KEY=...   # your own key
python3 tests/siliconflow/bench.py
```
The checked-in `bench-results.json` is a summary only. The sample is small, so treat the numbers as indicative.

## Releasing
1. `./build.sh` and zip the app: `ditto -c -k --keepParent build/Speakless.app Speakless-<version>-macos.zip`
2. Create a GitHub release and attach the zip. The app is not notarized yet, so first launch needs right-click → Open.
