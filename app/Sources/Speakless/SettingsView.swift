import SwiftUI
import AppKit

struct SettingsOverlay: View {
    @EnvironmentObject var app: AppState
    @Environment(\.layout) private var layout

    var body: some View {
        // 弹窗不会比窗口大：窗口小，它就跟着小；很窄时左边的导航收成图标
        let w = min(940, max(340, layout.width - 24))
        let h = min(650, max(340, layout.height - 24))
        let narrow = w < 700
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { app.showSettings = false }
            HStack(spacing: 0) {
                VStack(alignment: narrow ? .center : .leading, spacing: 2) {
                    ForEach(SettingsPage.allCases) { p in
                        Button(action: { app.settingsPage = p }) {
                            HStack(spacing: 10) {
                                Image(systemName: p.icon).font(.system(size: narrow ? 16 : 14)).frame(width: 18)
                                if !narrow {
                                    Text(p.rawValue).font(.system(size: 14.5))
                                    Spacer()
                                }
                            }
                            .foregroundColor(app.settingsPage == p ? Theme.text : Theme.secondary)
                            .padding(.horizontal, narrow ? 0 : 12)
                            .frame(width: narrow ? 44 : nil, height: narrow ? 40 : 36)
                            .frame(maxWidth: narrow ? 44 : .infinity)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(app.settingsPage == p ? Theme.navActive : Color.clear))
                                .hoverBorder(radius: 9, strength: 0.8)
                        }.buttonStyle(.plain).help(p.rawValue)
                    }
                    Spacer()
                }
                .padding(narrow ? 8 : 12)
                .frame(width: narrow ? 62 : 204)
                .background(Theme.sidebar)

                ZStack(alignment: .topTrailing) {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            switch app.settingsPage {
                            case .account: AccountPage()
                            case .settings: GeneralPage()
                            case .models: ModelsPage()
                            case .personalization: PersonalizationPage()
                            case .about: AboutPage()
                            case .help: HelpPage()
                            }
                        }
                        .padding(.horizontal, narrow ? 16 : 34).padding(.vertical, narrow ? 22 : 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(action: { app.showSettings = false }) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.secondary)
                            .frame(width: 28, height: 28)
                    }.buttonStyle(.plain).padding(10)
                }
                .background(Theme.panel)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        }
    }
}

// MARK: - 通用小部件

struct SectionHeader: View {
    let icon: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .medium)).foregroundColor(Theme.secondary)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .padding(.top, 22).padding(.bottom, 4)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var desc: String? = nil
    var soon = false
    @ViewBuilder var control: () -> Control

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 14.5, weight: .semibold))
                if soon {
                    Text("Soon").font(.system(size: 10, weight: .medium)).foregroundColor(Theme.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Theme.navActive))
                }
            }
            if let desc { Text(desc).font(.system(size: 13.5)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    var body: some View {
        let ctl = control().opacity(soon ? 0.5 : 1).disabled(soon)
        rowBody(ctl)
    }

    @State private var hover = false

    /// 鼠标放在这一行上：整行淡淡亮一下，看得出你在操作哪一项
    @ViewBuilder private func rowBody(_ ctl: some View) -> some View {
        layout(ctl)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover && !soon ? Theme.navActive.opacity(0.45) : Color.clear))
            .padding(.horizontal, -10).padding(.vertical, -6)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }

    @ViewBuilder private func layout(_ ctl: some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                labels.frame(minWidth: 200, alignment: .leading)
                Spacer(minLength: 16)
                ctl
            }
            VStack(alignment: .leading, spacing: 8) {
                labels
                ctl
            }
        }
        .padding(.vertical, 10)
    }
}

struct PageTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 28, weight: .semibold, design: .rounded)).padding(.bottom, 4) }
}

struct SwitchControl: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
    }
}

// MARK: - Settings

struct GeneralPage: View {
    @EnvironmentObject var app: AppState
    @State private var mics: [MicDevice] = []

    var body: some View {
        PageTitle(text: "Settings")
        SectionHeader(icon: "keyboard", title: "Shortcuts")
        SettingRow(title: "Dictate", desc: "Press to start and stop dictation.") { DictateShortcutEditor() }
        SettingRow(title: "Translate", desc: "Press to start and stop translation.", soon: true) {
            HStack(spacing: 6) { KeyChip(text: "Fn"); KeyChip(text: "Right Cmd") }
        }
        SettingRow(title: "Ask anything", desc: "Say a question and the answer appears in a small box, nothing is typed into your app. While you are already dictating, press this to switch that recording to a question. Tip: set it to your dictate key plus Space.") {
            DictateShortcutEditor(keyPath: \.askShortcuts)
        }
        SettingRow(title: "Search the web for answers", desc: "When a question needs fresh facts, Ask anything searches Bing once (DuckDuckGo if that fails). Only the search keywords are sent, never your audio, selection or window text.") {
            SwitchControl(isOn: Binding(get: { app.settings.askWebSearch }, set: { app.settings.askWebSearch = $0 }))
        }

        SectionHeader(icon: "text.viewfinder", title: "Context")
        SettingRow(title: "Window and web page", desc: "Window title, and for browsers the page title and site, so the tone fits where you are typing.") {
            SwitchControl(isOn: Binding(get: { app.settings.contextWindow }, set: { app.settings.contextWindow = $0 }))
        }
        SettingRow(title: "Input type", desc: "Whether you are in a code editor, and whether the place you type supports Markdown.") {
            SwitchControl(isOn: Binding(get: { app.settings.contextInputType }, set: { app.settings.contextInputType = $0 }))
        }
        SettingRow(title: "Text around the cursor", desc: "About 400 characters before and 300 after the cursor, so names and wording match and it knows whether you are replying or starting fresh.") {
            SwitchControl(isOn: Binding(get: { app.settings.contextCursorText }, set: { app.settings.contextCursorText = $0 }))
        }
        SettingRow(title: "Selected text", desc: "The text you have selected. Dictating over a selection replaces it; Ask anything works on it.") {
            SwitchControl(isOn: Binding(get: { app.settings.contextSelected }, set: { app.settings.contextSelected = $0 }))
        }
        SettingRow(title: "Visible text in the window", desc: "Up to about 1,500 characters of other text you can see in the window. The most sensitive one.") {
            SwitchControl(isOn: Binding(get: { app.settings.contextScreen }, set: { app.settings.contextScreen = $0 }))
        }
        SettingRow(title: "Never read these apps", desc: "App names or bundle ids, separated by commas. Password fields are never read. Everything above is sent to your correction platform only; a local platform keeps it on your network.") {
            TextField("WeChat, com.apple.Passwords", text: Binding(
                get: { app.settings.contextBlockedApps.joined(separator: ", ") },
                set: { app.settings.contextBlockedApps = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                .fieldHighlight().frame(width: 260)
        }

        SectionHeader(icon: "globe", title: "Language")
        SettingRow(title: "Interface language", desc: "Choose the language used in the user interface.", soon: true) {
            Text("English (US)").font(.system(size: 14)).padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke.opacity(2)))
        }
        SettingRow(title: "Translation targets", desc: "Choose up to 3 target languages for your dictation in translation mode.", soon: true) {
            Text("English (US)").font(.system(size: 14)).padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke.opacity(2)))
        }

        SectionHeader(icon: "mic", title: "Audio")
        SettingRow(title: "Microphone", desc: "Choose your preferred microphone for Speakless to capture your voice.") {
            Picker("", selection: Binding(get: { app.settings.microphoneUID ?? "" }, set: { app.settings.microphoneUID = $0.isEmpty ? nil : $0 })) {
                Text("Auto-detect (\(AudioDevices.defaultName()))").tag("")
                ForEach(mics) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().frame(width: 230)
        }
        RecorderLogView()
        SettingRow(title: "Interaction sounds", desc: "Play sounds for key actions like start/stop.") {
            SwitchControl(isOn: Binding(get: { app.settings.interactionSounds }, set: { app.settings.interactionSounds = $0 }))
        }
        SettingRow(title: "Sound style", desc: "Pick how start, stop and done sound. Press play to hear all three.") {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { app.settings.soundStyle }, set: { app.settings.soundStyle = $0 })) {
                    ForEach(SoundStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                Button(action: { Sounds.preview(app.settings.soundStyle) }) {
                    Image(systemName: "play.fill").font(.system(size: 11)).frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.navActive))
                }.buttonStyle(.plain)
            }
        }
        SettingRow(title: "Mute when dictating", desc: "Automatically silence other active audio during dictation.") {
            SwitchControl(isOn: Binding(get: { app.settings.muteWhenDictating }, set: { app.settings.muteWhenDictating = $0 }))
        }

        SettingRow(title: "Recognise while you speak", desc: "Only for speech models that run on your own machine (no key). Each time you pause, the part before the pause is recognised right away, so only the last bit is left to wait for when you stop. Correction still runs once over the whole text. If any part fails, it recognises the whole recording again.") {
            SwitchControl(isOn: Binding(get: { app.settings.streamWhileSpeaking }, set: { app.settings.streamWhileSpeaking = $0 }))
        }
        if app.settings.streamWhileSpeaking {
            SettingRow(title: "Only split recordings longer than", desc: "A recording shorter than this is never split: it is recognised whole, in one go, once you stop.") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { app.settings.streamStartAfterSeconds }, set: { app.settings.streamStartAfterSeconds = $0 }), in: 5...120, step: 5)
                        .frame(width: 140)
                    Text("\(Int(app.settings.streamStartAfterSeconds)) s").font(.system(size: 14)).frame(width: 40, alignment: .trailing)
                }
            }
            SettingRow(title: "Pause that starts a new part", desc: "How long you must stay quiet before the part so far is sent off. Shorter means more parts, which can cost a little accuracy.") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { app.settings.streamPauseSeconds }, set: { app.settings.streamPauseSeconds = $0 }), in: 1...4, step: 0.5)
                        .frame(width: 140)
                    Text(String(format: "%.1f s", app.settings.streamPauseSeconds)).font(.system(size: 14)).frame(width: 40, alignment: .trailing)
                }
            }
        }

        SectionHeader(icon: "doc.on.clipboard", title: "Clipboard")
        SettingRow(title: "Keep dictated text on the clipboard", desc: "Handy if the paste misses, for example when you switch windows while it's working: just press ⌘V yourself.") {
            Picker("", selection: Binding(get: { app.settings.clipboardMode }, set: { app.settings.clipboardMode = $0 })) {
                ForEach(ClipboardMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 300)
        }
        if app.settings.clipboardMode == .slow {
            SettingRow(title: "Slower than", desc: "Measured from the moment you stop speaking to the text being ready. Faster than this, your previous clipboard is put back.") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { app.settings.clipboardSlowSeconds }, set: { app.settings.clipboardSlowSeconds = $0 }), in: 0.1...5, step: 0.1)
                        .frame(width: 150).tint(Theme.accent)
                    Text(String(format: "%.1f s", app.settings.clipboardSlowSeconds)).font(.system(size: 14)).frame(width: 44, alignment: .trailing)
                }
            }
        }
        Text("If you switch to another window while it's working, Speakless never pastes into the wrong place. It only copies the text.")
            .font(.system(size: 12.5)).foregroundColor(Theme.secondary).padding(.bottom, 4)

        SectionHeader(icon: "laptopcomputer", title: "General")
        SettingRow(title: "Appearance", desc: "Choose between light and dark modes.") {
            Picker("", selection: Binding(get: { app.settings.appearance }, set: { app.settings.appearance = $0 })) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 150)
        }
        SettingRow(title: "Launch app at login", desc: "Open Speakless automatically when your computer starts.") {
            SwitchControl(isOn: Binding(get: { app.settings.launchAtLogin }, set: { app.settings.launchAtLogin = $0 }))
        }
        SettingRow(title: "Show app in dock", desc: "Display Speakless in your Mac dock for quick access.") {
            SwitchControl(isOn: Binding(get: { app.settings.showInDock }, set: { app.settings.showInDock = $0 }))
        }
        Color.clear.frame(height: 1).onAppear { mics = AudioDevices.inputs() }
    }
}

// MARK: - Personalization / Account / About / Help

struct PersonalizationPage: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        PageTitle(text: "Personalization")
        SectionHeader(icon: "book", title: "Vocabulary")
        SettingRow(title: "Use my dictionary as hints", desc: "\(app.dictionary.count) words in your dictionary are sent to the correction model so names and jargon are spelled your way.") {
            SwitchControl(isOn: Binding(get: { app.settings.useDictionaryHints }, set: { app.settings.useDictionaryHints = $0 }))
        }
        SettingRow(title: "Learn from my corrections", desc: "After you dictate, if you fix a misheard name or term in the text box, Speakless adds the right spelling to your dictionary. It only looks at the text box you just dictated into (never password fields), only for about 40 seconds, and keeps nothing.") {
            SwitchControl(isOn: Binding(get: { app.settings.learnFromCorrections }, set: { app.settings.learnFromCorrections = $0 }))
        }
        LearningLogView()
        SectionHeader(icon: "slider.horizontal.3", title: "Correction prompt")
        CorrectionPromptEditor()
        SectionHeader(icon: "text.alignleft", title: "Extra instructions for correction")
        Text("Optional. Anything you want the correction step to always do, in your own words.")
            .font(.system(size: 13.5)).foregroundColor(Theme.secondary).padding(.vertical, 6)
        TextEditor(text: Binding(get: { app.settings.customInstructions }, set: { app.settings.customInstructions = $0 }))
            .font(.system(size: 14))
            .frame(height: 130)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .scrollContentBackground(.hidden)
        Text("For example: “Use full-width Chinese punctuation.” or “Keep English product names in lower case.”")
            .font(.system(size: 12.5)).foregroundColor(Theme.secondary).padding(.top, 6)
    }
}

struct AccountPage: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        PageTitle(text: "Account")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 22)).foregroundColor(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local mode").font(.system(size: 16, weight: .semibold))
                    Text("No account, no limits. You bring your own SiliconFlow key.").font(.system(size: 13.5)).foregroundColor(Theme.secondary)
                }
            }
            Divider().opacity(0.5)
            Text("Everything you dictate, your history and your dictionary live only in ~/Library/Application Support/Speakless on this Mac.")
                .font(.system(size: 13.5)).foregroundColor(Theme.secondary)
            Button("Show data folder") { NSWorkspace.shared.open(AppPaths.support) }.buttonStyle(OutlineButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(hover: false)
        .padding(.top, 14)
    }
}

struct AboutPage: View {
    var body: some View {
        PageTitle(text: "About")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                LogoMark().frame(width: 30, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Speakless").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("Version 0.1.0").font(.system(size: 13)).foregroundColor(Theme.secondary)
                }
            }
            Text("A voice-dictation app for macOS where you choose the speech and correction models yourself. Hold nothing, press a key, speak, press again, and clean text lands where your cursor is.")
                .font(.system(size: 13.5)).foregroundColor(Theme.secondary)
            Text("An independent personal project. Its look is modelled on Typeless; it is not made by, or affiliated with, Typeless.")
                .font(.system(size: 12.5)).foregroundColor(Theme.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(hover: false)
        .padding(.top, 14)
    }
}

struct HelpPage: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        PageTitle(text: "Help")
        SectionHeader(icon: "lock.shield", title: "Permissions")
        permission("Microphone", "To hear you.", app.perms.microphone, Permissions.requestMicrophone)
        permission("Input Monitoring", "To notice the dictation key (Fn).", app.perms.inputMonitoring, Permissions.requestInputMonitoring)
        permission("Accessibility", "To paste the text where your cursor is.", app.perms.accessibility, Permissions.requestAccessibility)

        SectionHeader(icon: "keyboard", title: "If the Fn key opens the emoji picker")
        Text("Open System Settings → Keyboard and set “Press 🌐 key to” to “Do Nothing”, otherwise macOS shows its own popup every time you tap Fn.")
            .font(.system(size: 13.5)).foregroundColor(Theme.secondary).padding(.vertical, 6)
        Button("Open Keyboard settings") {
            if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(u) }
        }.buttonStyle(OutlineButtonStyle())

        SectionHeader(icon: "questionmark.circle", title: "How it works")
        Text("1. Press your dictation key and speak.\n2. Press it again (or click ✓ on the bar) to stop.\n3. Speakless recognises, corrects and pastes the text into the app you were using.\n\nNothing pasted? Check Accessibility above — without it the text is only copied to your clipboard.")
            .font(.system(size: 13.5)).foregroundColor(Theme.secondary).padding(.vertical, 6)
    }

    private func permission(_ title: String, _ desc: String, _ ok: Bool, _ action: @escaping () -> Void) -> some View {
        SettingRow(title: title, desc: desc) {
            if ok {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundColor(Theme.green).font(.system(size: 13.5))
            } else {
                Button("Allow", action: action).buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}


/// 完整的纠错提示词编辑：三档预设 + 随便改 + 当场试一下
struct CorrectionPromptEditor: View {
    @EnvironmentObject var app: AppState
    @State private var sample = "我注册了一个对齐流动，到时候会有一些API key，放到点z s h r c里面"
    @State private var result = ""
    @State private var elapsed = ""
    @State private var testing = false

    private var current: String { DefaultPrompts.name(of: app.settings.correctionPrompt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This is what tells the correction model how much to change. A cautious prompt changes little; a loose one rewrites more. Pick a preset or edit it freely.")
                .font(.system(size: 13.5)).foregroundColor(Theme.secondary)
            HStack(spacing: 10) {
                PillTabs(items: ["Light", "Balanced", "Polish"], selection: Binding(
                    get: { current == "Custom" ? "" : current },
                    set: { choose($0) }))
                if current == "Custom" {
                    Text("Custom").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Theme.accent.opacity(0.15)))
                }
                Spacer()
                Button("Reset to Polish") { app.settings.correctionPrompt = DefaultPrompts.polish }
                    .buttonStyle(OutlineButtonStyle())
            }
            Text(hint).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
            TextEditor(text: Binding(get: { app.settings.correctionPrompt }, set: { app.settings.correctionPrompt = $0 }))
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 260)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                .scrollContentBackground(.hidden)
            Text("Placeholders: {GLOSSARY} = your dictionary words, {EXTRA} = the extra instructions below, {APP} = the app you are typing in. {GLOSSARY} and {EXTRA} are added at the end for you if you leave them out.")
                .font(.system(size: 12.5)).foregroundColor(Theme.secondary)

            Text("Try it").font(.system(size: 14, weight: .semibold)).padding(.top, 8)
            TextField("Paste something the recogniser got wrong", text: $sample)
                .fieldHighlight()
            HStack(spacing: 10) {
                Button(testing ? "Correcting…" : "Run correction") { run() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(testing || sample.isEmpty)
                Text("Uses \(app.provider(app.settings.correction.providerId)?.name ?? "?") · \(ModelCatalog.title(for: app.settings.correctorModel, in: ModelCatalog.correctors)) · one small paid call each time")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
            }
            if !result.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result).font(.system(size: 14)).textSelection(.enabled)
                    if !elapsed.isEmpty { Text(elapsed).font(.system(size: 12)).foregroundColor(Theme.secondary) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardInner))
            }
        }
        .padding(.top, 6)
    }

    private var hint: String {
        switch current {
        case "Light": return "Light: fixes only what it is very sure about. Keeps your wording and filler words."
        case "Balanced": return "Balanced: fixes recognition mistakes, adds punctuation, removes filler words. Doesn't reword."
        case "Polish": return "Polish (default): fixes mistakes, drops fillers, keeps only your final wording when you correct yourself, puts the point first, splits long sentences, turns spoken lists into bullet points, and first works out who you are talking to (an AI, a teacher by email, a group notice, a friend, your own notes) and formats accordingly."
        default: return "Custom prompt."
        }
    }

    private func choose(_ name: String) {
        switch name {
        case "Light": app.settings.correctionPrompt = DefaultPrompts.light
        case "Balanced": app.settings.correctionPrompt = DefaultPrompts.balanced
        case "Polish": app.settings.correctionPrompt = DefaultPrompts.polish
        default: break
        }
    }

    private func run() {
        testing = true; result = ""; elapsed = ""
        let setup = app.setup(), g = app.glossary, text = sample
        let s = setup.settings
        Task {
            let t0 = Date()
            do {
                let out = try await ModelClient.shared.correct(text: text, glossary: g, extra: s.customInstructions, prompt: s.correctionPrompt, appName: "备忘录", setup: setup)
                onMain { result = out; elapsed = String(format: "%.1f s", Date().timeIntervalSince(t0)); testing = false }
            } catch {
                onMain { result = "Failed: \(error.localizedDescription)"; testing = false }
            }
        }
    }
}


/// 把用量送给 Token Monitor（它的「多设备同步」中心）
struct TokenMonitorSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var live = Live.shared
    @State private var secret = ""
    @State private var secretSaved = (try? String(contentsOf: UsageReporter.secretFile, encoding: .utf8))?.isEmpty == false

    var body: some View {
        SectionHeader(icon: "chart.bar.xaxis", title: "Token Monitor")
        SettingRow(title: "Report usage to Token Monitor", desc: "Every recognition and correction call is counted and sent as a client called “siliconflow”. Costs are estimates from SiliconFlow's price list, not your bill.") {
            SwitchControl(isOn: Binding(get: { app.settings.reportToTokenMonitor }, set: { app.settings.reportToTokenMonitor = $0; UsageReporter.shared.sendNow() }))
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Hub address").font(.system(size: 13)).foregroundColor(Theme.secondary)
            TextField("http://127.0.0.1:17321", text: Binding(get: { app.settings.tokenMonitorHubURL }, set: { app.settings.tokenMonitorHubURL = $0 }))
                .fieldHighlight()
            HStack(spacing: 8) {
                SecureField(secretSaved ? "Secret saved — type a new one to replace" : "Secret (only if you set one in Token Monitor)", text: $secret)
                    .fieldHighlight()
                Button("Save") {
                    try? secret.trimmingCharacters(in: .whitespacesAndNewlines).write(to: UsageReporter.secretFile, atomically: true, encoding: .utf8)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: UsageReporter.secretFile.path)
                    secretSaved = !secret.isEmpty; secret = ""; UsageReporter.shared.sendNow()
                }.buttonStyle(OutlineButtonStyle())
            }
            HStack(spacing: 10) {
                Button("Send now") { UsageReporter.shared.sendNow() }.buttonStyle(PrimaryButtonStyle())
                Text(live.usageStatus).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
            }
            Text("In Token Monitor: Settings → Multi-device Sync → host from this widget. Leave the secret empty for a localhost-only hub.")
                .font(.system(size: 12.5)).foregroundColor(Theme.secondary)
        }
        .padding(.top, 6)
    }
}


/// 自动学习的日志：每次听写后它做了什么、为什么没学到，都写在这里
struct LearningLogView: View {
    @State private var text = ""
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                Text("After each dictation, this says whether Speakless could see the text box, what you changed, and what it decided. If an app says it “doesn't hand over the text”, learning can't work there.")
                    .font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                ScrollView {
                    Text(text.isEmpty ? "Nothing yet. Dictate into a text box, change a name, wait a moment." : text)
                        .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 170).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardInner))
                HStack(spacing: 8) {
                    Button("Refresh") { load() }.buttonStyle(OutlineButtonStyle())
                    Button("Clear") { AutoLearn.clearLog(); load() }.buttonStyle(OutlineButtonStyle())
                }
            }.padding(.top, 8)
        } label: {
            Text("Learning log").font(.system(size: 14, weight: .semibold))
        }
        .padding(.vertical, 8)
        .onChange(of: open) { if $0 { load() } }
    }

    private func load() {
        text = AutoLearn.readLog().split(separator: "\n").suffix(60).reversed().joined(separator: "\n")
    }
}


/// 麦克风/录音日志：通话之后录不到声音、麦克风切换失败时，先看这里
struct RecorderLogView: View {
    @State private var text = ""
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Each recording notes which microphone and format it used, how loud it was, and any restarts. If dictation hears nothing after a call, send this to whoever is helping you.")
                    .font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                ScrollView {
                    Text(text.isEmpty ? "Nothing yet." : text)
                        .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 170).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardInner))
                HStack(spacing: 8) {
                    Button("Refresh") { load() }.buttonStyle(OutlineButtonStyle())
                    Button("Clear") { RecLog.clear(); load() }.buttonStyle(OutlineButtonStyle())
                }
            }.padding(.top, 8)
        } label: {
            Text("Microphone log").font(.system(size: 14, weight: .semibold))
        }
        .padding(.vertical, 8)
        .onChange(of: open) { if $0 { load() } }
    }

    private func load() {
        text = RecLog.read().split(separator: "\n").suffix(60).reversed().joined(separator: "\n")
    }
}
