import SwiftUI
import AppKit

// MARK: - Settings → Models：平台、识别模型、纠错模型，各自独立设置

struct ModelsPage: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        PageTitle(text: "Models")
        Text("Speech recognition and correction are set up separately. Each one picks its own platform, model and parameters, so they can use different companies, or the same one. Add as many platforms as you like.")
            .font(.system(size: 13.5)).foregroundColor(Theme.secondary)

        SectionHeader(icon: "server.rack", title: "Platforms")
        PlatformsSection()

        SectionHeader(icon: "mic", title: "Speech recognition")
        RolePanel(kind: .asr)

        SectionHeader(icon: "wand.and.stars", title: "Correction")
        SettingRow(title: "Correct recognition mistakes", desc: "Fixes misheard names and mixed Chinese / English terms, and tidies the wording. Off = you get the raw recognition result.") {
            SwitchControl(isOn: Binding(get: { app.settings.correctionEnabled }, set: { app.settings.correctionEnabled = $0; app.refreshPermissions() }))
        }
        if app.settings.correctionEnabled {
            RolePanel(kind: .correction)
            SettingRow(title: "Give up after", desc: "If correction is slower than this, the original text is used so you never wait. Long dictations get extra time automatically (up to +15 s).") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { app.settings.correctionTimeout }, set: { app.settings.correctionTimeout = $0 }), in: 2...15, step: 1)
                        .frame(width: 150).tint(Theme.accent)
                    Text("\(Int(app.settings.correctionTimeout)) s").font(.system(size: 14)).frame(width: 36, alignment: .trailing)
                }
            }
        }

        TokenMonitorSection()
    }
}

// MARK: - 平台列表

struct PlatformsSection: View {
    @EnvironmentObject var app: AppState
    @State private var open: String? = nil

    private var addable: [ProviderPreset] { ProviderCatalog.presets }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(app.providers) { p in
                ProviderCard(id: p.id, isOpen: open == p.id) { open = (open == p.id ? nil : p.id) }
            }
            HStack {
                Menu {
                    ForEach(addable, id: \.id) { pr in
                        Button(pr.name) { add(pr) }
                    }
                    Divider()
                    Button("Custom (any OpenAI-compatible service)…") { addCustom(noKey: false) }
                    Button("Custom, no key (a server you run yourself)…") { addCustom(noKey: true) }
                } label: { Label("Add platform", systemImage: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke.opacity(2)))
                Spacer()
            }
        }
        .padding(.top, 6)
    }

    private func add(_ pr: ProviderPreset) {
        // 同一个模板可以加多份（比如两台 Ollama）：第二份起 id 和名字带序号
        var made = ProviderCatalog.make(pr)
        if app.providers.contains(where: { $0.id == pr.id }) {
            var n = 2
            while app.providers.contains(where: { $0.id == "\(pr.id)-\(n)" }) { n += 1 }
            made.id = "\(pr.id)-\(n)"
            made.name = "\(pr.name) \(n)"
        }
        app.providers.append(made)
        open = made.id
    }

    private func addCustom(noKey: Bool) {
        let id = "custom-" + String(UUID().uuidString.prefix(6)).lowercased()
        app.providers.append(Provider(id: id, name: noKey ? "My server" : "My platform", baseURL: noKey ? "http://" : "https://", auth: noKey ? .none : .bearer))
        open = id
    }
}

struct ProviderCard: View {
    let id: String
    let isOpen: Bool
    let toggle: () -> Void
    @EnvironmentObject var app: AppState
    @State private var keyInput = ""
    @State private var status = ""
    @State private var busy = false
    @State private var keyVersion = 0

    private var p: Binding<Provider> { app.providerBinding(id) }
    private var preset: ProviderPreset? { ProviderCatalog.preset(for: id) }

    var body: some View {
        let prov = p.wrappedValue
        let _ = keyVersion
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(prov.name).font(.system(size: 14.5, weight: .semibold))
                        Text(prov.hostLabel).font(.system(size: 12)).foregroundColor(Theme.secondary)
                    }
                    Spacer()
                    if app.settings.asr.providerId == id { badge("Speech") }
                    if app.settings.correction.providerId == id { badge("Correction") }
                    keyChip(prov)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 11)).foregroundColor(Theme.secondary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Divider().opacity(0.5)
                editor(prov).padding(14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .hoverBorder(radius: 12, strength: 0.8)
    }

    private func badge(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Theme.accent)
            .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.accent.opacity(0.15)))
    }

    private func keyChip(_ prov: Provider) -> some View {
        let ok = KeyStore.hasKey(prov)
        return HStack(spacing: 5) {
            Circle().fill(ok ? Theme.green : Theme.danger).frame(width: 7, height: 7)
            Text(prov.requiresKey ? (ok ? "Key saved" : "No key") : "No key needed").font(.system(size: 12)).foregroundColor(Theme.secondary)
        }
    }

    @ViewBuilder private func editor(_ prov: Provider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let n = preset?.note, !n.isEmpty { Text(n).font(.system(size: 12.5)).foregroundColor(Theme.secondary) }
            labeled("Name") { TextField("Name", text: p.name).fieldHighlight() }
            labeled("Base URL") {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("https://…/v1", text: p.baseURL).fieldHighlight().font(.system(size: 13, design: .monospaced))
                    Text("Requests go to this address plus the paths under Advanced.").font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                }
            }
            if prov.requiresKey {
                labeled("API key") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SecureField(KeyStore.hasKey(prov) ? "Saved: \(KeyStore.masked(KeyStore.load(prov) ?? "")) — paste a new one to replace" : "Paste the key", text: $keyInput)
                                .fieldHighlight()
                            Button("Save") { saveKey() }.buttonStyle(PrimaryButtonStyle()).disabled(keyInput.trimmingCharacters(in: .whitespaces).count < 8)
                        }
                        HStack(spacing: 8) {
                            if let env = preset?.envVar, !env.isEmpty {
                                Button("Import \(env) from ~/.zshrc") { importKey(env) }.buttonStyle(OutlineButtonStyle())
                            }
                            if KeyStore.hasKey(prov) && FileManager.default.fileExists(atPath: KeyStore.file(id).path) {
                                Button("Remove key") { KeyStore.clear(id); keyVersion += 1; app.refreshPermissions(); status = "Key removed" }.buttonStyle(OutlineButtonStyle())
                            }
                        }
                    }
                }
            }
            labeled("Authentication") {
                VStack(alignment: .leading, spacing: 3) {
                    Picker("", selection: p.auth) { ForEach(AuthStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 260)
                    if prov.requiresKey { Text("Does your server need no key? Choose “No key (local server)”.").font(.system(size: 11.5)).foregroundColor(Theme.secondary) }
                }
            }
            labeled("Network") {
                VStack(alignment: .leading, spacing: 3) {
                    Picker("", selection: p.network) { ForEach(NetworkMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 260)
                    Text(prov.network == .auto ? "Auto picked: \(prov.goesDirect ? "direct, no proxy (domestic or local address)" : "the system proxy (foreign address)")" : "Set by you")
                        .font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                }
            }
            if prov.isLocalModel {
                labeled("Unloads after idle") {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            TextField("", value: p.keepAliveMinutes, format: .number).fieldHighlight().frame(width: 70)
                            Text("minutes (0 = never unloads)").font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                        }
                        Text("How long your server keeps the model loaded when nobody uses it. Once it has sat unused that long it counts as cold: pressing record starts loading it right away, and the first request waits longer. The time of the last use is remembered, so restarting the app doesn't make it cold.")
                            .font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                    }
                }
                labeled("Load time") {
                    HStack(spacing: 6) {
                        TextField("", value: p.loadAllowanceSeconds, format: .number).fieldHighlight().frame(width: 70)
                        Text("seconds of extra waiting when it is cold").font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                    }
                }
                labeled("Status & warm-up") {
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("My server has a status and warm-up endpoint", isOn: p.statusAPI).toggleStyle(.switch)
                        if prov.statusAPI {
                            HStack(spacing: 6) {
                                Text("Status (GET)").font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                                TextField("/health", text: p.statusPath).fieldHighlight().frame(width: 110)
                                Text("Warm-up (POST)").font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                                TextField("/warmup", text: p.warmupPath).fieldHighlight().frame(width: 110)
                            }
                        }
                        Text("Off by default, because this is not a standard OpenAI or Ollama endpoint. Turn it on only if your server answers GET on the status path with JSON containing \"loaded\" (true/false) and optionally \"busy\", and loads the model in the background on POST to the warm-up path. Paths are relative to the server address without /v1. Without it, Speakless warms the model by sending a short speech clip instead.")
                            .font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(busy ? "Checking…" : "Test connection & fetch models") { fetch() }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                if !prov.models.isEmpty { Text("\(prov.models.count) models known").font(.system(size: 12.5)).foregroundColor(Theme.secondary) }
            }
            if !status.isEmpty { Text(status).font(.system(size: 12.5)).foregroundColor(Theme.secondary) }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    labeled("Chat path") { TextField("/chat/completions", text: p.chatPath).fieldHighlight().font(.system(size: 13, design: .monospaced)) }
                    labeled("Transcription path") { TextField("/audio/transcriptions", text: p.transcriptionPath).fieldHighlight().font(.system(size: 13, design: .monospaced)) }
                    labeled("Models path") { TextField("/models", text: p.modelsPath).fieldHighlight().font(.system(size: 13, design: .monospaced)) }
                    labeled("Extra headers") {
                        VStack(alignment: .leading, spacing: 3) {
                            TextEditor(text: p.extraHeaders).font(.system(size: 12.5, design: .monospaced)).frame(height: 56).scrollContentBackground(.hidden)
                                .padding(4).background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardInner))
                            Text("One per line, like  X-Title: Speakless").font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                        }
                    }
                }.padding(.top, 6)
            }
            .font(.system(size: 13.5))

            if !prov.builtin || prov.id != "siliconflow" {
                if app.isInUse(id) {
                    Text("This platform is in use by speech recognition or correction. Choose another one there before removing it.")
                        .font(.system(size: 12)).foregroundColor(Theme.secondary)
                } else {
                    Button("Remove platform", role: .destructive) {
                        KeyStore.clear(id)
                        app.providers.removeAll { $0.id == id }
                    }.buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        let c = content()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                Text(title).font(.system(size: 13)).foregroundColor(Theme.secondary).frame(width: 128, alignment: .leading).padding(.top, 5)
                c
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13)).foregroundColor(Theme.secondary)
                c
            }
        }
    }

    private func saveKey() {
        do { try KeyStore.save(keyInput, for: id); keyInput = ""; keyVersion += 1; app.refreshPermissions(); status = "Key saved" }
        catch { status = "Couldn't save the key: \(error.localizedDescription)" }
    }

    private func importKey(_ env: String) {
        if let k = KeyStore.importFromZshrc(envVar: env) {
            do { try KeyStore.save(k, for: id); keyVersion += 1; app.refreshPermissions(); status = "Imported \(env) from ~/.zshrc" }
            catch { status = "Couldn't save the key: \(error.localizedDescription)" }
        } else { status = "No \(env) found in ~/.zshrc" }
    }

    private func fetch() {
        busy = true; status = ""
        let prov = p.wrappedValue
        Task {
            do {
                let ids = try await ModelClient.shared.fetchModels(provider: prov)
                onMain {
                    if let i = app.providers.firstIndex(where: { $0.id == id }) { app.providers[i].models = ids }
                    status = "Connected. \(ids.count) models available."; busy = false
                }
            } catch {
                onMain { status = error.localizedDescription; busy = false }
            }
        }
    }
}

// MARK: - 一个用途（识别 / 纠错）：平台 + 模型 + 参数

struct RolePanel: View {
    let kind: RoleKind
    @EnvironmentObject var app: AppState
    @State private var testing = false
    @State private var result = ""

    private var role: Binding<RoleConfig> { kind == .asr ? $app.settings.asr : $app.settings.correction }
    private var provider: Provider { app.provider(role.wrappedValue.providerId) ?? Provider(id: "?", name: "Missing platform", baseURL: "") }
    private var effective: Params { Resolver.effective(role.wrappedValue, kind: kind, provider: provider) }
    private var isManual: Bool { role.wrappedValue.mode == .manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Platform") {
                Picker("", selection: Binding(get: { role.wrappedValue.providerId }, set: { changePlatform($0) })) {
                    ForEach(app.providers) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(width: 300)
            }
            row("Model") {
                VStack(alignment: .leading, spacing: 4) {
                    ModelField(model: role.model, provider: provider, kind: kind)
                    if let note = modelNote { Text(note).font(.system(size: 12)).foregroundColor(Theme.secondary) }
                }
            }
            row("Parameters") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: Binding(get: { role.wrappedValue.mode }, set: { setMode($0) })) {
                        Text("Auto").tag(ParamMode.auto); Text("Manual").tag(ParamMode.manual)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    Text(isManual ? "You are in control: edit anything below. Switch back to Auto to let the app decide."
                                  : "Auto fills these from the platform and model. This is exactly what will be sent. Switch to Manual to change any of them.")
                        .font(.system(size: 12)).foregroundColor(Theme.secondary)
                }
            }
            ParamRows(p: Binding(get: { effective }, set: { new in
                if isManual { var r = role.wrappedValue; r.manual = new; role.wrappedValue = r }
            }), kind: kind, provider: provider, editable: isManual)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))

            HStack(spacing: 10) {
                Button(testing ? "Testing…" : (kind == .asr ? "Test with my last recording" : "Test with a sample sentence")) { runTest() }
                    .buttonStyle(OutlineButtonStyle()).disabled(testing)
                Text("One small paid call.").font(.system(size: 12)).foregroundColor(Theme.secondary)
            }
            if !result.isEmpty {
                Text(result).font(.system(size: 13)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.cardInner))
            }
        }
        .padding(.top, 6)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        let c = content()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).frame(width: 90, alignment: .leading).padding(.top, 5)
                c
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                c
            }
        }
    }

    private var modelNote: String? {
        let id = role.wrappedValue.model
        let list = kind == .asr ? ModelCatalog.asr : ModelCatalog.correctors
        if provider.id.hasPrefix("siliconflow"), let m = list.first(where: { $0.id == id }) { return m.note }
        if id.trimmingCharacters(in: .whitespaces).isEmpty { return "Pick a model for this platform, or type its id." }
        return nil
    }

    private func suggestions(for p: Provider) -> [String] {
        let pr = ProviderCatalog.preset(for: p.id)
        return (kind == .asr ? pr?.asrModels : pr?.correctionModels) ?? []
    }

    private func changePlatform(_ id: String) {
        var r = role.wrappedValue
        guard r.providerId != id else { return }
        r.providerId = id
        if let p = app.provider(id) {
            let sug = suggestions(for: p)
            if !sug.contains(r.model) { r.model = sug.first ?? "" }
        }
        role.wrappedValue = r
        app.refreshPermissions()
    }

    private func setMode(_ m: ParamMode) {
        var r = role.wrappedValue
        if m == .manual && r.mode == .auto { r.manual = Resolver.autoParams(kind: kind, provider: provider, model: r.model) }
        r.mode = m
        role.wrappedValue = r
    }

    private func runTest() {
        testing = true; result = ""
        let setup = app.setup()
        let gloss = app.glossary
        if kind == .asr {
            guard let item = app.history.first(where: { FileManager.default.fileExists(atPath: app.audioURL($0.id).path) }),
                  let wav = try? Data(contentsOf: app.audioURL(item.id)) else {
                result = "No saved recording yet. Dictate once, then test again."; testing = false; return
            }
            Task {
                let t0 = Date()
                do {
                    let text = try await ModelClient.shared.transcribe(wav: wav, setup: setup, glossary: gloss)
                    onMain { result = "\(String(format: "%.1f", Date().timeIntervalSince(t0))) s  ·  \(text)"; testing = false }
                } catch { onMain { result = "Failed: \(error.localizedDescription)"; testing = false } }
            }
        } else {
            Task {
                let t0 = Date()
                do {
                    let text = try await ModelClient.shared.correct(text: "我注册了一个对齐流动，到时候会有一些API key，放到点z s h r c里", glossary: gloss,
                                                                     extra: setup.settings.customInstructions, prompt: setup.settings.correctionPrompt, appName: "备忘录", setup: setup)
                    onMain { result = "\(String(format: "%.1f", Date().timeIntervalSince(t0))) s  ·  \(text)"; testing = false }
                } catch { onMain { result = "Failed: \(error.localizedDescription)"; testing = false } }
            }
        }
    }
}

// MARK: - 模型名输入框：可以直接打字，也可以从建议和平台模型列表里选

struct ModelField: View {
    @Binding var model: String
    let provider: Provider
    let kind: RoleKind

    private var suggestions: [String] {
        let pr = ProviderCatalog.preset(for: provider.id)
        return (kind == .asr ? pr?.asrModels : pr?.correctionModels) ?? []
    }

    private func looksLikeASR(_ id: String) -> Bool {
        let m = id.lowercased()
        return ["asr", "whisper", "transcribe", "speech", "voice", "sensevoice", "omni", "audio", "stt", "parakeet"].contains { m.contains($0) }
    }

    private var fetched: [String] {
        let list = provider.models.filter { !suggestions.contains($0) }
        let filtered = list.filter { kind == .asr ? looksLikeASR($0) : !looksLikeASR($0) }
        return Array((filtered.isEmpty ? list : filtered).prefix(150))
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Model id", text: $model).fieldHighlight().font(.system(size: 13, design: .monospaced))
            Menu {
                if !suggestions.isEmpty {
                    Section("Suggested") { ForEach(suggestions, id: \.self) { s in Button(s) { model = s } } }
                }
                if !fetched.isEmpty {
                    Section("From this platform (\(provider.models.count))") { ForEach(fetched, id: \.self) { s in Button(s) { model = s } } }
                }
                if suggestions.isEmpty && fetched.isEmpty {
                    Text("Use “Test connection & fetch models” on the platform above, or type a model id.")
                }
            } label: { Text("Choose") }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        }
    }
}

// MARK: - 参数表：自动模式下显示自动选了什么；手动模式下可以改

struct ParamRows: View {
    @Binding var p: Params
    let kind: RoleKind
    let provider: Provider
    let editable: Bool

    private var endpoint: String {
        var base = provider.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        let path: String
        if kind == .asr && p.asrProtocol == .transcriptions { path = provider.transcriptionPath } else { path = provider.chatPath }
        return base + (path.hasPrefix("/") ? path : "/" + path)
    }

    var body: some View {
        VStack(spacing: 0) {
            line("Endpoint", fixed: true) { Text(endpoint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(2) }
            line("Authentication", fixed: true) { Text(provider.auth.rawValue).font(.system(size: 12.5)) }
            line("Network", fixed: true) { Text(provider.goesDirect ? "Direct, no proxy" : "System proxy").font(.system(size: 12.5)) }
            if kind == .asr {
                line("Method") {
                    Picker("", selection: $p.asrProtocol) { ForEach(ASRProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 290)
                }
                if p.asrProtocol == .chatAudio {
                    line("Audio format") {
                        Picker("", selection: $p.chatAudioFormat) { ForEach(ChatAudioFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 290)
                    }
                    line("Max output tokens") { TextField("", value: $p.maxTokens, format: .number).fieldHighlight().frame(width: 90) }
                }
                line("Language hint") { TextField("auto", text: $p.language).fieldHighlight().frame(width: 90) }
                line("Dictionary as a hint") { SwitchControl(isOn: $p.vocabularyHint) }
            } else {
                line("Temperature") { TextField("", value: $p.temperature, format: .number).fieldHighlight().frame(width: 90) }
                line("Max output tokens") { TextField("", value: $p.maxTokens, format: .number).fieldHighlight().frame(width: 90) }
                line("Thinking parameter") {
                    Picker("", selection: $p.thinking) { ForEach(ThinkingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 290)
                }
            }
            if kind == .asr {
                line("Request timeout (s)") {
                    if editable {
                        HStack(spacing: 8) {
                            TextField("", value: $p.timeout, format: .number).fieldHighlight().frame(width: 90)
                            Text("0 = auto, by recording length").font(.system(size: 12)).foregroundColor(Theme.secondary)
                        }
                    } else if p.timeout > 0 {
                        Text("\(Int(p.timeout)) s").font(.system(size: 12.5))
                    } else {
                        Text(p.asrProtocol == .chatAudio ? "Auto · 15 s + 1 s per second of speech (max 120 s)" : "Auto · 8 s + 0.6 s per second of speech (max 60 s)").font(.system(size: 12.5))
                    }
                }
            } else {
                line("Request timeout (s)") { TextField("", value: $p.timeout, format: .number).fieldHighlight().frame(width: 90) }
            }
            line("Price (usage estimate)", last: true) { priceControls }
        }
    }

    @ViewBuilder private var priceControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Text(p.priceKnown ? "Known" : "Unknown").font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                SwitchControl(isOn: $p.priceKnown)
            }
            if p.priceKnown {
                HStack(spacing: 8) {
                    Picker("", selection: $p.priceCurrency) { Text("CNY ¥").tag("CNY"); Text("USD $").tag("USD") }.labelsHidden().frame(width: 90)
                    if kind == .asr {
                        TextField("per second", value: $p.audioPricePerSecond, format: .number).fieldHighlight().frame(width: 90)
                        Text("per second of audio").font(.system(size: 12)).foregroundColor(Theme.secondary)
                        if p.asrProtocol == .chatAudio {
                            TextField("in /M", value: $p.inputPricePerM, format: .number).fieldHighlight().frame(width: 70)
                            TextField("out /M", value: $p.outputPricePerM, format: .number).fieldHighlight().frame(width: 70)
                        }
                    } else {
                        TextField("in /M", value: $p.inputPricePerM, format: .number).fieldHighlight().frame(width: 80)
                        TextField("out /M", value: $p.outputPricePerM, format: .number).fieldHighlight().frame(width: 80)
                        Text("per million tokens").font(.system(size: 12)).foregroundColor(Theme.secondary)
                    }
                }
            } else {
                Text("Calls will show “no price” in the usage card.").font(.system(size: 11.5)).foregroundColor(Theme.secondary)
            }
        }
    }

    /// fixed = 由「平台」决定，在这里只读
    private func line<C: View>(_ title: String, fixed: Bool = false, last: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        let c = content().disabled(!editable || fixed).opacity(fixed ? 0.8 : (editable ? 1 : 0.75))
        return VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    Text(title).font(.system(size: 13)).foregroundColor(Theme.secondary).frame(width: 150, alignment: .leading).padding(.top, 4)
                    Spacer(minLength: 8)
                    c
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13)).foregroundColor(Theme.secondary)
                    c
                }
            }
            .padding(.vertical, 7)
            if !last { Divider().opacity(0.35) }
        }
    }
}
