import SwiftUI
import AppKit

@main
struct SpeaklessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(AppState.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 750)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppState.shared.openSettings() }.keyboardShortcut(",")
            }
        }
    }
}

extension AppState {
    func openSettings(_ page: SettingsPage = .settings) {
        WindowManager.shared.show()
        settingsPage = page
        showSettings = true
    }
}

/// 关窗口时只是藏起来（软件继续在菜单栏里待命，快捷键照常能用）。
/// 也负责「放大」：双击窗口最上面那一条（或者菜单 Window → Zoom），在「你自己拖的大小」和「默认大小」之间切换。
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    weak var window: NSWindow?
    private var monitor: Any?

    /// 默认窗口大小
    static let defaultSize = NSSize(width: 1080, height: 750)

    func adopt(_ w: NSWindow) {
        guard window !== w else { return }
        window = w
        w.delegate = self
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        installDoubleClickMonitor()
    }

    /// 标题栏是隐藏的，系统自带的「双击标题栏放大」用不上，所以自己认：
    /// 在窗口最上面 44 点高的一条里双击，就当作双击标题栏。
    private func installDoubleClickMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let w = self.window, event.window === w, event.clickCount == 2 else { return event }
            if event.locationInWindow.y > w.frame.height - 44 {
                w.zoom(nil)
                return nil
            }
            return event
        }
    }

    /// 「放大」要去的大小：默认大小（屏幕放不下时就缩到屏幕那么大），保持窗口左上角不动
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let screen = window.screen?.visibleFrame ?? defaultFrame
        let size = NSSize(width: min(Self.defaultSize.width, screen.width), height: min(Self.defaultSize.height, screen.height))
        var frame = NSRect(origin: NSPoint(x: window.frame.minX, y: window.frame.maxY - size.height), size: size)
        frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - size.width))
        frame.origin.y = max(screen.minY, min(frame.origin.y, screen.maxY - size.height))
        return frame
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { WindowManager.shared.adopt(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { WindowManager.shared.adopt(w) } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        NSSetUncaughtExceptionHandler { e in
            RecLog.write("UNCAUGHT EXCEPTION \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.prefix(12).joined(separator: "\n"))
        }
        if let i = args.firstIndex(of: "--context-test"), i + 1 < args.count {
            // 开发用：等 6 秒（这期间切到要测的软件），读取最前面软件的场景信息，再用它做一次「问点什么」，结果写进文件
            let out = args[i + 1]
            if i + 3 < args.count {   // 可选：把指定 bundle id 的软件调到最前面
                for t in [1.0, 3.0, 5.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                        NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 3]).first?.activate(options: [.activateIgnoringOtherApps])
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                let fa = i + 3 < args.count ? NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 3]).first : NSWorkspace.shared.frontmostApplication
                let st = AppState.shared.settings
                if i + 2 < args.count {   // 可选：在最前面软件的输入框里选中这段文字
                    var wref: CFTypeRef?
                    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(fa?.processIdentifier ?? 0), kAXFocusedWindowAttribute as CFString, &wref)
                    if let wref, let el = ContextCapture.findFocusedText(in: wref as! AXUIElement) {
                        var v: CFTypeRef?
                        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let t = v as? String,
                           let r = t.range(of: args[i + 2]) {
                            var cf = CFRange(location: NSRange(r, in: t).location, length: NSRange(r, in: t).length)
                            if let av = AXValueCreate(.cfRange, &cf) { AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, av) }
                        }
                    }
                }
                let c = ContextCapture.capture(pid: fa?.processIdentifier ?? 0, appName: fa?.localizedName ?? "", bundle: fa?.bundleIdentifier, settings: st)
                var text = "trusted=\(AXIsProcessTrusted())\n" + c.promptBlock() + "\n"
                do {
                    var f: CFTypeRef?
                    let e1 = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &f)
                    var g: CFTypeRef?
                    let e2 = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(fa?.processIdentifier ?? 0), kAXFocusedUIElementAttribute as CFString, &g)
                    text += "focus: system err \(e1.rawValue), app err \(e2.rawValue)\n"
                    if let el = ((f ?? g).map { $0 as! AXUIElement }) {
                        var r: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
                        var v: CFTypeRef?; let e3 = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
                        var sr: CFTypeRef?; let e4 = AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &sr)
                        text += "role \(r as? String ?? "?"), value err \(e3.rawValue) len \((v as? String)?.count ?? -1), range err \(e4.rawValue)\n"
                    }
                }
                let sem = DispatchSemaphore(value: 0)
                Task {
                    let setup = AppState.shared.setup()
                    let q1 = try? await ModelClient.shared.answer(question: "这句话里的“方便的话”是什么意思", glossary: [], context: c, search: true, setup: setup)
                    text += "\nASK1 → \(q1?.text ?? "FAILED") [sources \(q1?.sources.count ?? 0)]\n"
                    let q2 = try? await ModelClient.shared.answer(question: "今天上海的天气怎么样", glossary: [], context: AppContext(), search: true, setup: setup)
                    text += "\nASK2 → \(q2?.text ?? "FAILED") [query \(q2?.query ?? "-"), sources \(q2?.sources.count ?? 0)]\n"
                    let d = try? await ModelClient.shared.correct(text: "那个我就是想说周五我可能去不了你把资料发我一下", glossary: [], extra: "", prompt: DefaultPrompts.polish, appName: fa?.localizedName ?? "", context: c, setup: setup)
                    text += "DICTATE → \(d ?? "FAILED")\n"
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 90)
                try? text.write(toFile: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        if args.contains("--mic-test") {
            runMicTest()
            return
        }
        if let i = args.firstIndex(of: "--correct-test"), i + 1 < args.count {
            // 开发用：文件里每行「软件名|识别出来的文字」，用当前默认提示词各整理一遍（不录音、不记用量）
            let lines = ((try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            Task {
                let setup = AppState.shared.setup()
                for l in lines {
                    let parts = l.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let out = (try? await ModelClient.shared.correct(text: parts[1], glossary: AppState.shared.glossary, extra: "", prompt: DefaultPrompts.polish, appName: parts[0], setup: setup)) ?? "FAILED"
                    print("[\(parts[0])] \(parts[1])\n  → \(out.replacingOccurrences(of: "\n", with: "⏎"))\n")
                }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--correct-test"), i + 1 < args.count {
            // 开发用：文件里每行「软件名|识别出来的文字」，用当前默认提示词各整理一遍（不录音、不记用量）
            let lines = ((try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            Task {
                let setup = AppState.shared.setup()
                for l in lines {
                    let parts = l.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let out = (try? await ModelClient.shared.correct(text: parts[1], glossary: AppState.shared.glossary, extra: "", prompt: DefaultPrompts.polish, appName: parts[0], setup: setup)) ?? "FAILED"
                    print("[\(parts[0])] \(parts[1])\n  → \(out.replacingOccurrences(of: "\n", with: "⏎"))\n")
                }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            runSelfTest(path: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--dump-sounds"), i + 1 < args.count {
            dumpSounds(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--render-bar"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in self.renderBars(to: dir) }
            return
        }
        if let i = args.firstIndex(of: "--probe-ax"), i + 1 < args.count {
            // 开发用：看某个软件的输入框能不能被读到（只记录角色和文字长度，不记录文字内容），结果写进学习日志
            let bundle = args[i + 1]
            DispatchQueue.global().async {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { AutoLearn.log("probe \(bundle): not running"); exit(0) }
                let root = AXUIElementCreateApplication(app.processIdentifier)
                func scan(_ label: String) {
                    var queue: [(AXUIElement, Int)] = [(root, 0)]
                    var seen = 0, fields: [String] = []
                    while !queue.isEmpty, seen < 4000 {
                        let (el, depth) = queue.removeFirst(); seen += 1
                        var r: CFTypeRef?
                        let role = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success ? (r as? String ?? "") : ""
                        if role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox" {
                            var v: CFTypeRef?
                            let ok = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success
                            let n = (v as? String)?.count
                            fields.append("\(role): value \(ok ? "readable, \(n ?? -1) chars" : "NOT readable")")
                        }
                        if depth < 14 {
                            var c: CFTypeRef?
                            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &c) == .success, let kids = c as? [AXUIElement] { kids.forEach { queue.append(($0, depth + 1)) } }
                        }
                    }
                    AutoLearn.log("probe \(app.localizedName ?? bundle) [\(label)]: scanned \(seen) elements, text fields: \(fields.isEmpty ? "none found" : fields.joined(separator: "; "))")
                }
                AutoLearn.clearLog()
                scan("before switch")
                AutoLearn.enableManualAccessibility(pid: app.processIdentifier)
                Thread.sleep(forTimeInterval: 2.5)
                scan("after AXManualAccessibility")
                exit(0)
            }
            return
        }
        if args.contains("--learn-e2e") {
            // 开发用：在自己窗口里放一个原生输入框，假装刚听写完、再「手改」一个词，看自动学习能不能走完全程
            NSApp.setActivationPolicy(.regular)
            let dictated = "我在测试 quibbleks macbook 这个软件"
            let win = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 560, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            let scroll = NSTextView.scrollableTextView()
            let tv = scroll.documentView as! NSTextView
            tv.string = "前面有一些别的话。" + dictated + "后面还有别的话。"
            win.contentView = scroll
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            win.makeFirstResponder(tv)
            AutoLearn.clearLog()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AutoLearn.shared.begin(inserted: dictated, appName: "E2E", pid: getpid())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                tv.string = tv.string.replacingOccurrences(of: "quibbleks", with: "Quibblex")   // 模拟你手动改了一个词
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
                print(AutoLearn.readLog())
                let added = AppState.shared.dictionary.filter { $0.word == "Quibblex" }
                print("dictionary now has Quibblex: \(!added.isEmpty)")
                AppState.shared.dictionary.removeAll { $0.word == "Quibblex" }   // 清理，不留在你的词典里
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--ui-test"), i + 1 < args.count {
            // 开发用：另开一个只有界面的窗口、指定大小，用来检查窗口缩小后的排版（不监听按键、不上报、不出声）
            let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
            let size = NSSize(width: parts.first ?? 720, height: parts.count > 1 ? parts[1] : 800)
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 }) else { return }
                w.setContentSize(size)
                w.setFrameOrigin(NSPoint(x: 40, y: (NSScreen.main?.visibleFrame.maxY ?? 800) - size.height - 40))
                if let dir = ProcessInfo.processInfo.environment["SPEAKLESS_SNAP_DIR"] { self.snapPages(window: w, to: dir) }
            }
            return
        }
        if let i = args.firstIndex(of: "--provider-test"), i + 1 < args.count {
            // 开发用：用一个「自定义平台」（地址指向硅基流动）把手动参数、聊天式识别、拉模型列表都走一遍
            let path = args[i + 1]
            Task {
                var s = AppSettings()
                let prov = Provider(id: "siliconflow-test", name: "Custom test", baseURL: "https://api.siliconflow.cn/v1/")
                s.asr = RoleConfig(providerId: prov.id, model: "FunAudioLLM/SenseVoiceSmall", mode: .manual, manual: Params(timeout: 60, asrProtocol: .transcriptions, language: "zh"))
                var setup = Setup(settings: s, providers: [prov])
                do {
                    let wav = try Data(contentsOf: URL(fileURLWithPath: path))
                    let ids = try await ModelClient.shared.fetchModels(provider: prov)
                    print("1) fetchModels: \(ids.count) models, first: \(ids.first ?? "-")")
                    let a = try await ModelClient.shared.transcribe(wav: wav, setup: setup)
                    print("2) transcriptions API, manual params (SenseVoice, language=zh): \(a.prefix(60))")
                    setup.settings.asr = RoleConfig(providerId: prov.id, model: "Qwen/Qwen3-Omni-30B-A3B-Instruct", mode: .auto)
                    let eff = Resolver.effective(setup.settings.asr, kind: .asr, provider: prov)
                    print("   auto picked for Omni: protocol=\(eff.asrProtocol), audio=\(eff.chatAudioFormat), timeout=\(eff.timeout)")
                    let b = try await ModelClient.shared.transcribe(wav: wav, setup: setup)
                    print("3) chat-with-audio (audio_url), auto params (Qwen3-Omni): \(b.prefix(60))")
                    var m = Params(); m.temperature = 0.2; m.maxTokens = 300; m.thinking = .omit
                    setup.settings.correction = RoleConfig(providerId: prov.id, model: "deepseek-ai/DeepSeek-V4.1-Flash", mode: .manual, manual: m)
                    let c = try await ModelClient.shared.correct(text: "我注册了一个对齐流动", glossary: ["硅基流动"], extra: "", prompt: DefaultPrompts.light, appName: "备忘录", setup: setup)
                    print("4) correction, manual (temp 0.2, max 300, no thinking param): \(c)")
                    var bad = prov; bad.baseURL = "https://127.0.0.1:9/v1"
                    setup.providers = [bad]
                    do { _ = try await ModelClient.shared.fetchModels(provider: bad) } catch { print("5) unreachable platform gives a readable error: \(error.localizedDescription.prefix(80))") }
                    exit(0)
                } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if let i = args.firstIndex(of: "--render-layout"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in self.renderLayouts(to: dir) }
            return
        }
        if args.contains("--learn-test") {
            // 开发用：检查「改了哪几处」的比对逻辑（不联网）
            let cases: [(String, String)] = [
                ("我在测试 spikeless macbook starry 这个软件", "我在测试 Speakless macbook starry 这个软件"),
                ("我注册了一个对齐流动，到时候会有 API key", "我注册了一个硅基流动，到时候会有 API key"),
                ("斯皮克里斯 和 对齐流动 都在用", "Speakless 和 硅基流动 都在用"),
                ("今天下午三点开会", "今天下午四点开会，在二楼"),
            ]
            for (o, n) in cases {
                let hs = AutoLearn.hunks(old: AutoLearn.tokenize(o), new: AutoLearn.tokenize(n))
                print("「\(o)」→「\(n)」")
                for h in hs { print("   改动: \(AutoLearn.join(h.old)) → \(AutoLearn.join(h.new))   上下文: \(h.context)") }
            }
            print("valid(Speakless):", AutoLearn.valid(term: "Speakless", changed: "Speakless", context: "测试 Speakless macbook starry"))
            print("valid(整句):", AutoLearn.valid(term: "Speakless macbook starry", changed: "Speakless", context: "测试 Speakless macbook starry"))
            print("valid(Speakless macbook):", AutoLearn.valid(term: "Speakless macbook", changed: "Speakless", context: "测试 Speakless macbook starry"))
            print("valid(把整句收进去):", AutoLearn.valid(term: "我注册了一个硅基流动到时候", changed: "硅基", context: "我注册了一个硅基流动到时候"))
            print("valid(硅基流动):", AutoLearn.valid(term: "硅基流动", changed: "硅基", context: "了一个硅基流动，到时候"))
            exit(0)
        }
        if args.contains("--payload-demo") {
            // 开发用：用几条假记录生成一份上报内容，打印出来（不联网、不写文件）
            let now = Date()
            func rec(_ ago: Double, _ kind: String, _ model: String, _ i: Int, _ o: Int, _ sec: Double, _ cost: Double, _ priced: Bool) -> UsageRecord {
                UsageRecord(ts: now.addingTimeInterval(-ago), kind: kind, model: model, inputTokens: i, outputTokens: o, audioSeconds: sec, costUsd: cost, priced: priced)
            }
            var rs: [UsageRecord] = []
            rs.append(rec(0, "asr", "Qwen/Qwen3-ASR-1.7B", 0, 0, 14.9, 0.0005, true))
            rs.append(rec(0, "correct", "deepseek-ai/DeepSeek-V4.1-Flash", 910, 70, 0, 0.00036, true))
            rs.append(rec(259200, "correct", "Qwen/Qwen3.5-122B-A10B", 880, 60, 0, 0.00018, true))
            rs.append(rec(0, "asr", "Qwen/Qwen3-Omni-30B-A3B-Instruct", 200, 40, 0, 0, false))
            let data = try! JSONSerialization.data(withJSONObject: UsageReporter.payload(records: rs, now: now), options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            exit(0)
        }
        if args.contains("--demo-bar") {
            runBarDemo()
            return
        }
        let state = AppState.shared
        state.applyAppearance()
        state.applyActivationPolicy()
        setupStatusItem()

        let monitor = HotKeyMonitor.shared
        monitor.shortcuts = state.settings.dictateShortcuts
        monitor.askShortcuts = state.settings.askShortcuts
        monitor.onFire = { DictationController.shared.toggle() }
        monitor.onFireAsk = { DictationController.shared.toggleAsk() }
        monitor.onEscape = { DictationController.shared.cancel() }
        _ = DictationController.shared
        Sounds.warmUp()
        UsageReporter.shared.start()

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        tick()

        if let i = args.firstIndex(of: "--fail-test"), i + 1 < args.count {
            // 开发用：用一段 wav 走完整流程（平台地址故意连不上），看失败后有没有 Retry、录音有没有留下
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DictationController.shared.debugRun(wavPath: args[i + 1]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { NSApp.terminate(nil) }
        }
        if args.contains("--undo-test") {
            // 开发用：像自动学习那样加一个词并弹出带「Undo」的提示；点了 Undo 词会被删掉，结果写进录音日志
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let e = AppState.shared.addWord("UndoTestWord", auto: true)
                RecLog.write("undo-test: added, dictionary has it = \(AppState.shared.dictionary.contains { $0.word == "UndoTestWord" })")
                DictationController.shared.notice("Added “UndoTestWord” to Dictionary", undo: {
                    if let e { AppState.shared.dictionary.removeAll { $0.id == e.id } }
                    RecLog.write("undo-test: UNDO CLICKED, dictionary has it = \(AppState.shared.dictionary.contains { $0.word == "UndoTestWord" })")
                })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) }
        }
        if args.contains("--esc-test") {
            // 开发用：开始听写 → 1.5 秒后发一个真的 Esc 按键 → 看听写有没有被中断（结果写进录音日志）
            func post(_ down: Bool) { let e = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down); e?.post(tap: .cghidEventTap) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                DictationController.shared.toggle()
                RecLog.write("esc-test: started, phase=\(Live.shared.phase)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { post(true); post(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                RecLog.write("esc-test: after Esc, phase=\(Live.shared.phase) (idle = interrupted)")
                NSApp.terminate(nil)
            }
        }
    }

    private func tick() {
        let state = AppState.shared
        state.refreshPermissions()
        let m = HotKeyMonitor.shared
        if !m.isRunning { m.start() } else { m.upgradeIfPossible() }
        if state.hotkeyActive != m.isRunning { state.hotkeyActive = m.isRunning }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 菜单栏图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Speakless")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Speakless", action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Start / Stop Dictation", action: #selector(toggleDictation), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Speakless", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openMain() { WindowManager.shared.show() }
    @objc private func toggleDictation() { DictationController.shared.toggle() }
    @objc private func openSettings() { AppState.shared.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 命令行自测：Speakless --selftest 某段.wav
    // 只测 识别 + 纠错 这条链路（会调用一次识别、一次纠错），不涉及麦克风和快捷键

    private func runSelfTest(path: String) {
        Task {
            do {
                let wav = try Data(contentsOf: URL(fileURLWithPath: path))
                let setup = AppState.shared.setup()
                let s = setup.settings
                let t0 = Date()
                let raw = try await ModelClient.shared.transcribe(wav: wav, setup: setup, glossary: AppState.shared.glossary)
                print("ASR  [\(s.asr.providerId) · \(s.asr.model)] \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n  \(raw)")
                let t1 = Date()
                let fixed = try await ModelClient.shared.correct(text: raw, glossary: AppState.shared.glossary,
                                                                 extra: s.customInstructions, prompt: s.correctionPrompt, appName: "备忘录", setup: setup)
                print("FIX  [\(s.correction.providerId) · \(s.correction.model)] \(Int(Date().timeIntervalSince(t1) * 1000)) ms\n  \(fixed)")
                exit(0)
            } catch {
                print("FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    // MARK: 开发用：把提示音导出成 wav，方便检查波形（不会播放）

    private func dumpSounds(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for style in SoundStyle.allCases where style != .system {
            for kind in [SoundKind.start, .stop, .done, .error] {
                try? Synth.wav(style: style, kind: kind).write(to: URL(fileURLWithPath: "\(dir)/\(style.rawValue)-\(kind.rawValue).wav"))
            }
        }
        exit(0)
    }

    // MARK: 开发用：只演示悬浮条的动画（不录音、不监听按键）

    private func runBarDemo() {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.windows.forEach { $0.orderOut(nil) } }
        let live = Live.shared
        let bar = VoiceBarController()
        // 主线程卡顿检测：每 4 毫秒看一次，记录两次之间最长隔了多久
        let demoStart = CFAbsoluteTimeGetCurrent()
        var lastTick = demoStart, maxGap = 0.0, slow = 0, ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.004, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            let gap = now - lastTick; lastTick = now
            ticks += 1
            maxGap = max(maxGap, gap)
            if gap > 0.034 { slow += 1; print(String(format: "  stall %.0f ms at t=%.2fs", gap * 1000, now - demoStart)); fflush(stdout) }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            print(String(format: "main thread: max gap %.0f ms, gaps over 34 ms: %d (of %d ticks)", maxGap * 1000, slow, ticks)); fflush(stdout)
            maxGap = 0; slow = 0; ticks = 0
        }
        var t: Double = 0
        Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            t += 0.04
            guard live.phase == .recording else { return }
            let v = Float(max(0, sin(t * 3.1)) * (0.35 + 0.65 * Double.random(in: 0...1)))
            LevelMeter.shared.level = v
        }
        func cycle() {
            live.barMessage = nil; live.barNotice = nil
            live.phase = .recording; bar.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { live.phase = .processing }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { live.phase = .idle; bar.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { live.barNotice = "Added “硅基流动” to Dictionary"; bar.show() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { live.barNotice = nil; bar.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 11.5) { cycle() }
        }
        cycle()
    }

    // MARK: 开发用：把悬浮条的每个状态渲染成图片，方便检查样子

    @MainActor private func renderBars(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let live = Live.shared
        live.barVisible = true
        LevelMeter.shared.preview = [0.95, 0.85, 0.7, 0.8, 0.55, 0.4, 0.5, 0.3, 0.25]
        let states: [(String, () -> Void)] = [
            ("1-recording", { live.phase = .recording }),
            ("2-processing", { live.phase = .processing }),
            ("3-notice", { live.phase = .idle; live.barNotice = "Added “硅基流动” to Dictionary" }),
            ("4-error", { live.barNotice = nil; live.barMessage = "Microphone access denied" }),
        ]
        for (name, apply) in states {
            apply()
            let view = VoiceBarView().frame(width: 420, height: 72)
                .background(Color(white: 0.62))
            let r = ImageRenderer(content: view)
            r.scale = 3
            if let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
        exit(0)
    }

    // MARK: 开发用：把各个页面按不同窗口宽度渲染成图片，检查有没有被挤掉的元素

    @MainActor private func renderLayouts(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let app = AppState.shared
        let sizes: [(String, CGFloat, CGFloat)] = [("full", 1080, 750), ("half", 720, 820), ("narrow", 520, 700)]
        let shots: [(String, () -> Void)] = [
            ("home", { app.showSettings = false; app.page = .home }),
            ("dictionary", { app.showSettings = false; app.page = .dictionary }),
            ("settings-general", { app.showSettings = true; app.settingsPage = .settings }),
            ("settings-models", { app.showSettings = true; app.settingsPage = .models }),
        ]
        for (sizeName, w, h) in sizes {
            for (name, apply) in shots {
                apply()
                let view = MainView().environmentObject(app).frame(width: w, height: h)
                let r = ImageRenderer(content: view)
                r.scale = 1.5
                if let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/\(sizeName)-\(name).png"))
                }
            }
        }
        exit(0)
    }
}


/// 开发用：反复开关录音、依次试每个麦克风和一个不存在的麦克风，看会不会崩。结果写进录音日志。
/// 用法：open -a /Applications/Speakless.app --args --mic-test
func runMicTest() {
    DispatchQueue.global().async {
        RecLog.write("=== mic-test begin ===")
        let rec = Recorder()
        var targets: [String?] = [nil, "does-not-exist"]
        targets += AudioDevices.inputs().map { Optional($0.id) }
        for uid in targets {
            for round in 1...3 {
                let sem = DispatchSemaphore(value: 0)
                var failure: String?
                rec.start(deviceUID: uid) { err in failure = err?.localizedDescription; sem.signal() }
                sem.wait()
                Thread.sleep(forTimeInterval: round == 3 ? 0.05 : 0.8)
                if round == 2 { rec.restart(); Thread.sleep(forTimeInterval: 0.6) }
                let r = rec.stop()
                RecLog.write("test \(uid ?? "default") round \(round): \(failure.map { "FAILED \($0)" } ?? "ok") \(String(format: "%.2f", r.seconds)) s")
            }
        }
        RecLog.write("=== mic-test end — no crash ===")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}


extension AppDelegate {
    /// 开发用：依次切到几个页面，把窗口内容存成 PNG（不需要屏幕录制权限）。给宣传图截图用。
    func snapPages(window w: NSWindow, to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let app = AppState.shared
        let shots: [(String, () -> Void)] = [
            ("home", { app.showSettings = false; app.page = .home }),
            ("history", { app.showSettings = false; app.page = .history }),
            ("dictionary", { app.showSettings = false; app.page = .dictionary }),
            ("models", { app.showSettings = true; app.settingsPage = .models }),
            ("settings", { app.showSettings = true; app.settingsPage = .settings }),
            ("personalization", { app.showSettings = true; app.settingsPage = .personalization }),
        ]
        func step(_ i: Int) {
            guard i < shots.count else { exit(0) }
            shots[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(shots[i].0).png"))
                }
                step(i + 1)
            }
        }
        step(0)
    }
}
