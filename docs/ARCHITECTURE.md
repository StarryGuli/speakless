# Architecture

```
hotkey ─► Recorder ─► ASR provider ─► Corrector (LLM) ─► paste at cursor
             │            ▲                 ▲
             │            │                 └─ glossary + personal dictionary + context block
             └─ level meter / streaming segments
Ask key ─► same recording ─► Answer (LLM, optional web search) ─► answer panel
```

## Modules (`app/Sources/Speakless/`)

| File | Role |
|---|---|
| `SpeaklessApp.swift`, `AppState.swift` | App entry, shared state, wiring of hotkeys to the dictation flow |
| `Shortcuts.swift` | Global hotkeys via a CGEventTap: dictate and ask shortcuts, single modifiers or combos, duplicate guard |
| `Services.swift` | `Recorder` (AVAudioEngine, dB-scale level meter with auto-gain) and paste helpers |
| `Dictation.swift` | The state machine: begin → record → process → paste; also switches a running dictation into Ask mode |
| `Streaming.swift` | Splits audio into segments and transcribes them while you are still speaking |
| `API.swift` | `ModelClient`: transcription, correction (`correct`), answers (`answer`), provider warm-up |
| `Providers.swift`, `ModelsPage.swift` | Provider definitions (key / no-key, status & warm-up options) and their settings UI |
| `AppContext.swift` | Accessibility-based context capture: app, window title, URL, selection, text around the cursor, visible text |
| `WebSearch.swift` | Keyless Bing → DuckDuckGo search used by Ask |
| `AnswerBox.swift` | Non-activating floating panel for Ask answers |
| `AutoLearn.swift`, `DictionaryView.swift` | Personal dictionary and learning from your edits |
| `HistoryView.swift`, `UsageLog.swift` | History with per-stage timings, provider and model |
| `Theme.swift`, `MainView.swift`, `HomeView.swift`, `SettingsView.swift` | UI and shared styles (hover borders, focus highlight) |
| `Sources/CatchObjC` | Tiny Objective-C shim turning AVFoundation exceptions into Swift errors |

## Design decisions

- **Prompt caching.** The corrector's system prompt is a long fixed prefix; the per-request context block is appended at the very end so providers can cache the prefix.
- **Context is reference only.** The context block tells the model never to copy it into the output; each item can be turned off, and apps can be blocked.
- **Provider neutrality.** Standard OpenAI-compatible endpoints by default. The `/health` + `/warmup` style status API is opt-in per provider.
- **Local first.** A provider without an API key is treated as local; load times and keep-alive settings are tracked per provider.
- **No backend.** Everything runs on the user's Mac; settings, history and keys live in `~/Library/Application Support/Speakless/`.
