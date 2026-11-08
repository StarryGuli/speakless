import SwiftUI
import AppKit
import AVFoundation

/// 一次听写的完整流程：按键 → 录音 → 识别 → 纠错（超时就用原文）→ 写进光标处 → 记历史
final class DictationController {
    static let shared = DictationController()

    private let recorder = Recorder()
    private let bar = VoiceBarController()
    private var frontApp = ""
    private var frontBundle: String?
    private var frontPid: pid_t = 0
    private var wasMuted: Bool?
    private var task: Task<Void, Never>?
    private var maxTimer: Timer?
    private var silenceTimer: Timer?
    private var streamer: StreamASR?
    enum Mode { case dictate, ask }
    private var mode: Mode = .dictate
    /// 开始录音那一刻读到的场景信息（后台读取，处理时再取结果）
    private var ctxTask: Task<AppContext, Never>?
    /// 识别失败/超时后留下的那段录音，悬浮条上的 Retry 用它重来；同时会在历史里留一条（历史没关的话）
    private struct PendingRetry { var wav: Data; var seconds: Double; var front: String; var bundle: String?; var pid: pid_t; var historyID: UUID? }
    private var pending: PendingRetry?
    private var undoAction: (() -> Void)?
    private var app: AppState { AppState.shared }
    private var live: Live { Live.shared }

    init() {
        recorder.onLevel = { LevelMeter.shared.level = $0 }
        recorder.onLost = { [weak self] msg in
            guard let self, self.live.phase == .recording else { return }
            self.maxTimer?.invalidate()
            self.silenceTimer?.invalidate()
            _ = self.recorder.stop()
            self.streamer?.cancel(); self.streamer = nil
            self.restoreAudio()
            self.fail(msg)
        }
        bar.prepare()
    }

    /// 「问点什么」快捷键：和听写一样按一次开始、再按一次结束
    func toggleAsk() {
        // 听写录音进行中按「问点什么」的键：不结束，把这次录音切换成问答模式
        if live.phase == .recording, mode == .dictate {
            mode = .ask
            live.askMode = true
            Sounds.cue(.start)
            return
        }
        toggle(as: .ask)
    }
    func toggle() { toggle(as: .dictate) }

    private func toggle(as m: Mode) {
        switch live.phase {
        case .idle: mode = m; start()
        case .recording: finish()
        case .processing: break
        }
    }

    func cancel() {
        guard live.phase != .idle else { return }
        task?.cancel()
        if live.phase == .recording { _ = recorder.stop(); restoreAudio() }
        streamer?.cancel(); streamer = nil
        maxTimer?.invalidate()
        silenceTimer?.invalidate()
        live.phase = .idle
        live.askMode = false
        bar.hide()
        Sounds.cue(.stop)
    }

    // MARK: 开始

    private func start() {
        guard live.phase == .idle else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                onMain { ok ? self.begin() : self.fail("Microphone access denied") }
            }
        default:
            fail("Microphone is off — allow it in System Settings → Privacy & Security")
        }
    }

    private func begin() {
        if let missing = app.missingKeyProviders().first { return fail("Add the API key for \(missing.name) in Settings → Models") }
        AutoLearn.shared.cancel()
        AnswerPanelController.shared.close()
        live.askMode = (mode == .ask)
        live.barNotice = nil
        live.barMessage = nil
        live.barRetry = false
        frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        do {
            let st = app.settings, n = frontApp, b = frontBundle, p = frontPid
            ctxTask = Task.detached(priority: .userInitiated) { ContextCapture.capture(pid: p, appName: n, bundle: b, settings: st) }
        }
        ModelClient.shared.prewarm(setup: app.setup())   // 本机模型此时就开始装载，说完话时已就绪
        let s = app.settings
        recorder.skipSeconds = s.interactionSounds ? Sounds.lead(s.soundStyle) : 0

        // 先让界面和提示音立刻出来，再去启动麦克风（启动引擎要几百毫秒，放在后台，不卡动画）
        live.phase = .recording
        bar.show()
        Sounds.cue(.start)
        recorder.start(deviceUID: s.microphoneUID) { [weak self] error in
            guard let self, let error, self.live.phase == .recording else { return }
            self.maxTimer?.invalidate()
            self.silenceTimer?.invalidate()
            self.restoreAudio()
            self.fail("Can't start recording: \(error.localizedDescription)")
        }
        // 本机/自建识别模型：边说边识别（见 Streaming.swift）
        streamer?.cancel(); streamer = nil
        let st = app.setup()
        if s.streamWhileSpeaking, st.provider(s.asr.providerId)?.isLocalModel == true {
            let sa = StreamASR(recorder: recorder, setup: st, glossary: app.glossary, pause: s.streamPauseSeconds, startAfter: s.streamStartAfterSeconds)
            sa.start(); streamer = sa
        }
        // 开口说话前后 1.5 秒还是完全没声音：多半是麦克风被通话等占着，换一个全新的引擎再试一次
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, self.live.phase == .recording, self.recorder.currentPeak() < 0.0005 else { return }
            RecLog.write("no signal 1.5 s after start — rebuilding the audio engine")
            self.recorder.restart()
        }
        if s.muteWhenDictating {
            // 等开始提示音播完再静音，不然提示音自己也被静音了
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                let muted = SystemAudio.isMuted()
                onMain { self.wasMuted = muted }
                if !muted { SystemAudio.setMuted(true) }
            }
        }
        maxTimer?.invalidate()
        maxTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in self.finish() }
    }

    // MARK: 结束并处理

    private func finish() {
        guard live.phase == .recording else { return }
        maxTimer?.invalidate()
        silenceTimer?.invalidate()
        let (wav, seconds) = recorder.stop()
        let stats = recorder.lastStats
        let streamed = streamer?.finish()
        streamer = nil
        let tailPCM = streamed.map { Array(recorder.lastPCM.dropFirst($0.tailStart)) }
        restoreAudio()
        Sounds.cue(.stop)
        guard seconds >= 0.4 else {
            streamed?.tasks.forEach { $0.cancel() }
            live.phase = .idle
            bar.hide()
            return
        }
        // 几乎没有声音（麦克风被占用/静音/选错）：别送去识别，不然模型会对着噪声编出 “no, no”、“嗯”
        if stats.peak < 0.004 || stats.voicedSeconds < 0.15 {
            streamed?.tasks.forEach { $0.cancel() }
            live.phase = .idle
            Sounds.cue(.error)
            flash(stats.peak < 0.0005
                  ? "Microphone is silent — another app (a call?) may be using it. Try another mic in Settings → Audio."
                  : "Didn't hear anything — nothing was sent.", isError: true)
            return
        }
        live.phase = .processing
        let setup = app.setup()
        let glossary = app.glossary
        let front = frontApp
        let bundle = frontBundle
        let pid = frontPid
        let stoppedAt = Date()
        let pre = streamed.flatMap { s in s.tasks.isEmpty ? nil : Streamed(tasks: s.tasks, tail: tailPCM ?? []) }
        let ctx = ctxTask, runMode = mode
        ctxTask = nil; mode = .dictate
        task = Task { await self.process(wav: wav, seconds: seconds, front: front, bundle: bundle, pid: pid, stoppedAt: stoppedAt, setup: setup, glossary: glossary, pre: pre, mode: runMode, ctxTask: ctx) }
    }

    /// 边说边识别已经送出去的各段，加上最后剩下的一小段声音
    struct Streamed { var tasks: [Task<(text: String, ms: Int), Error>]; var tail: [Float] }

    private func restoreAudio() {
        guard app.settings.muteWhenDictating else { return }
        DispatchQueue.global().async {
            // 原来就是静音的话保持静音
            let was = onMainSync { self.wasMuted } ?? false
            if !was { SystemAudio.setMuted(false) }
        }
    }

    private func process(wav: Data, seconds: Double, front: String, bundle: String?, pid: pid_t, stoppedAt: Date, setup: Setup, glossary: [String], pre: Streamed? = nil, mode: Mode = .dictate, ctxTask: Task<AppContext, Never>? = nil) async {
        let settings = setup.settings
        var item = HistoryItem()
        item.appName = front
        item.kind = mode == .ask ? .ask : .dictation
        item.seconds = seconds
        item.asrModel = settings.asrModel
        item.asrProvider = settings.asr.providerId
        let asrProv = setup.provider(settings.asr.providerId)
        item.asrProviderName = asrProv?.name
        item.asrLocal = asrProv?.isLocalModel
        var segs: [Int] = []
        do {
            let t0 = Date()
            var rawText: String? = nil
            if let pre {
                // 前面的段落在说话时就已经识别了，这里只等最后一小段；任何一段失败就退回整段重新识别
                do {
                    var parts: [String] = []
                    for t in pre.tasks { let v = try await t.value; parts.append(v.text); segs.append(v.ms) }
                    if StreamASR.hasSpeech(pre.tail) {
                        let ts = Date()
                        parts.append(try await ModelClient.shared.transcribe(wav: Recorder.wav(from: pre.tail), setup: setup, glossary: glossary))
                        segs.append(Int(Date().timeIntervalSince(ts) * 1000))
                    }
                    let joined = StreamASR.join(parts)
                    if !joined.isEmpty { rawText = joined }
                    RecLog.write("streamed recognition: \(pre.tasks.count) segment(s) + tail, \(joined.count) chars")
                } catch {
                    RecLog.write("streamed recognition failed (\(error.localizedDescription)) — recognising the whole recording again")
                    segs = []
                }
            }
            let raw: String
            if let rawText { raw = rawText } else {
                let ts = Date()
                raw = try await ModelClient.shared.transcribe(wav: wav, setup: setup, glossary: glossary)
                segs = [Int(Date().timeIntervalSince(ts) * 1000)]
            }
            item.segmentsMs = segs
            item.loadMs = ModelClient.shared.takeLoadMs()
            if Task.isCancelled { pre?.tasks.forEach { $0.cancel() }; return }   // 按了 Esc
            item.asrMs = Int(Date().timeIntervalSince(t0) * 1000)
            item.raw = raw
            item.text = raw
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                onMain { self.live.phase = .idle; self.flash("No speech detected") }
                return
            }
            let context = await ctxTask?.value ?? AppContext(appName: front, bundleId: bundle)
            if mode == .ask {
                // 问点什么：说出来的话是一个问题，答案显示在回答框里，不往你正在写的地方粘贴
                let t1 = Date()
                item.correctorModel = settings.correctorModel
                item.correctorProvider = settings.correction.providerId
                let ap = setup.provider(settings.correction.providerId)
                item.correctorProviderName = ap?.name
                item.correctorLocal = ap?.isLocalModel
                onMain { self.live.phase = .idle; self.live.askMode = false; self.bar.hide() }
                AnswerPanelController.shared.show(question: raw)
                do {
                    let ans = try await ModelClient.shared.answer(question: raw, glossary: glossary, context: context, search: settings.askWebSearch, setup: setup,
                                                                  onStatus: { AnswerPanelController.shared.status($0) })
                    if Task.isCancelled { return }
                    item.correctionMs = Int(Date().timeIntervalSince(t1) * 1000)
                    item.text = ans.text
                    item.words = countWords(ans.text)
                    if let q = ans.query { item.note = "Searched the web: \(q)" }
                    AnswerPanelController.shared.finish(text: ans.text, sources: ans.sources, query: ans.query)
                    Sounds.cue(.done)
                } catch {
                    item.correctionMs = Int(Date().timeIntervalSince(t1) * 1000)
                    item.note = "Ask failed: \(error.localizedDescription)"
                    AnswerPanelController.shared.fail(error.localizedDescription)
                }
                let doneItem = item
                onMain { if self.app.settings.keepHistory != .never { self.app.addHistory(doneItem, wav: wav) } }
                return
            } else if settings.correctionEnabled {
                let t1 = Date()
                item.correctorModel = settings.correctorModel
                item.correctorProvider = settings.correction.providerId
                let corrProv = setup.provider(settings.correction.providerId)
                item.correctorProviderName = corrProv?.name
                item.correctorLocal = corrProv?.isLocalModel
                let result = await withTimeout(settings.correctionWait(forChars: raw.count, local: setup.provider(settings.correction.providerId)?.isLocalModel ?? false)) {
                    try await ModelClient.shared.correct(text: raw, glossary: glossary, extra: settings.customInstructions, prompt: settings.correctionPrompt, appName: front, context: context, setup: setup)
                }
                item.correctionMs = Int(Date().timeIntervalSince(t1) * 1000)
                switch result {
                case .success(let fixed) where !fixed.isEmpty:
                    item.text = fixed
                case .success:
                    item.note = "Correction returned nothing, kept the original."
                case .failure(let err):
                    item.note = "Correction skipped: \(err.localizedDescription)"
                }
            }
            if Task.isCancelled { return }
            item.words = countWords(item.text)
            let finalText = item.text
            let done = item
            onMain {
                // 从按下"结束"到文字准备好用了多久
                let elapsed = Date().timeIntervalSince(stoppedAt)
                let nowFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                // 你在等的时候切到别的窗口了（或者切到了 Speakless 自己）：不往那里粘贴，只复制，免得写错地方
                let switched = nowFront != bundle || nowFront == Bundle.main.bundleIdentifier
                let keep: Bool
                switch settings.clipboardMode {
                case .always: keep = true
                case .slow: keep = elapsed > settings.clipboardSlowSeconds
                case .never: keep = false
                }
                let outcome = Inserter.insert(finalText, restoreClipboard: !(keep || switched), paste: !switched)
                self.app.addHistory(done, wav: wav)
                self.live.phase = .idle
                Sounds.cue(.done)
                switch outcome {
                case .pasted:
                    AutoLearn.shared.begin(inserted: finalText, appName: front, pid: pid)
                    self.bar.hide()
                case .copiedOnly:
                    self.flash("Copied — you switched windows, so it wasn't pasted")
                case .copiedNoPermission:
                    self.flash("Copied — allow Accessibility to paste automatically")
                }
            }
        } catch {
            if Task.isCancelled { return }
            let msg = error.localizedDescription
            // 失败了也要把这段录音留下来：历史里存一条（可以在那边重试），悬浮条上给一个 Retry
            RecLog.write("recognition failed: \(msg) — recording kept for retry")
            var failed = item
            failed.note = "Recognition failed: \(msg)"
            failed.text = ""; failed.raw = ""; failed.words = 0
            onMain {
                let keeps = self.app.settings.keepHistory != .never
                if keeps { self.app.addHistory(failed, wav: wav) }
                self.pending = PendingRetry(wav: wav, seconds: seconds, front: front, bundle: bundle, pid: pid, historyID: keeps ? failed.id : nil)
                self.live.phase = .idle
                self.failWithRetry(msg)
            }
        }
    }

    /// 开发用：拿一段 wav 当作刚录好的声音走一遍完整流程（配合 --fail-test）
    func debugRun(wavPath: String) {
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: wavPath)) else { return }
        live.phase = .processing
        bar.show()
        let setup = app.setup()
        task = Task { await self.process(wav: wav, seconds: 5, front: "Test", bundle: "com.test.none", pid: 0, stoppedAt: Date(), setup: setup, glossary: []) }
    }

    /// 悬浮条上的 Retry：用刚才失败的那段录音重新识别 + 整理 + 粘贴
    func retryPending() {
        guard live.phase == .idle, let p = pending else { return }
        pending = nil
        live.barRetry = false
        live.barMessage = nil
        if let id = p.historyID, let old = app.history.first(where: { $0.id == id }) { app.deleteHistory(old) }
        live.phase = .processing
        bar.show()
        let setup = app.setup()
        let glossary = app.glossary
        task = Task { await self.process(wav: p.wav, seconds: p.seconds, front: p.front, bundle: p.bundle, pid: p.pid, stoppedAt: Date(), setup: setup, glossary: glossary) }
    }

    private func failWithRetry(_ message: String) {
        Sounds.cue(.error)
        live.barRetry = true
        live.barMessage = message
        bar.show()
        scheduleErrorDismiss(message, after: 20)
    }

    private func scheduleErrorDismiss(_ text: String, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard self.live.barMessage == text else { return }
            if self.live.barHover { return self.scheduleErrorDismiss(text, after: 2) }   // 鼠标放在上面时不消失
            self.live.barMessage = nil
            self.live.barRetry = false
            if self.live.phase == .idle { self.bar.hide() }
        }
    }

    /// 历史里「Retry」：用同一段录音重新识别 + 纠错，更新那一条
    func retry(_ item: HistoryItem) {
        let url = app.audioURL(item.id)
        guard let wav = try? Data(contentsOf: url) else { return }
        let setup = app.setup()
        let settings = setup.settings
        let glossary = app.glossary
        Task {
            do {
                let raw = try await ModelClient.shared.transcribe(wav: wav, setup: setup, glossary: glossary)
                var fixed = raw
                var note: String? = nil
                if settings.correctionEnabled, !raw.isEmpty {
                    let r = await withTimeout(settings.correctionWait(forChars: raw.count, local: setup.provider(settings.correction.providerId)?.isLocalModel ?? false)) {
                        try await ModelClient.shared.correct(text: raw, glossary: glossary, extra: settings.customInstructions, prompt: settings.correctionPrompt, appName: item.appName, setup: setup)
                    }
                    if case .success(let t) = r, !t.isEmpty { fixed = t } else { note = "Correction skipped on retry." }
                }
                onMain {
                    guard let i = self.app.history.firstIndex(where: { $0.id == item.id }) else { return }
                    self.app.history[i].raw = raw
                    self.app.history[i].text = fixed
                    self.app.history[i].words = countWords(fixed)
                    self.app.history[i].asrModel = settings.asrModel
                    self.app.history[i].correctorModel = settings.correctionEnabled ? settings.correctorModel : nil
                    self.app.history[i].note = note
                }
            } catch {
                onMain { self.fail(error.localizedDescription) }
            }
        }
    }

    // MARK: 悬浮条上的提示

    /// 一条友好的提示（比如「已加入词典」）
    func notice(_ text: String, undo: (() -> Void)? = nil) {
        undoAction = undo
        live.noticeCanUndo = undo != nil
        live.barNotice = text
        bar.show()
        // 有「撤销」按钮的提示停留 9 秒，鼠标放在上面时一直不消失
        scheduleDismiss(text, after: undo != nil ? 9 : 2.6)
    }

    private func scheduleDismiss(_ text: String, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard self.live.barNotice == text else { return }
            if self.live.barHover { return self.scheduleDismiss(text, after: 1) }
            self.live.barNotice = nil
            self.live.noticeCanUndo = false
            self.undoAction = nil
            if self.live.phase == .idle && self.live.barMessage == nil { self.bar.hide() }
        }
    }

    func undoNotice() {
        undoAction?()
        undoAction = nil
        live.barNotice = "Removed"
        live.noticeCanUndo = false
        let t = "Removed"
        scheduleDismiss(t, after: 1.2)
    }

    private func fail(_ message: String) {
        live.phase = .idle
        Sounds.cue(.error)
        flash(message, isError: true)
    }

    private func flash(_ message: String, isError: Bool = false) {
        live.barMessage = message
        bar.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 3.5 : 2.2)) {
            if self.live.barMessage == message {
                self.live.barMessage = nil
                if self.live.phase == .idle { self.bar.hide() }
            }
        }
    }
}

func onMainSync<T>(_ f: () -> T) -> T {
    Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f)
}

// MARK: - 悬浮条（Voice bar）

final class VoiceBarController {
    private var panel: NSPanel?

    /// 启动时就把面板建好（第一次建 SwiftUI 视图要几十毫秒，放到按键之后会卡）
    func prepare() {
        onMain {
            _ = self.makePanelIfNeeded()
            // 提前把中文字体回退和图标装进缓存，第一次出现提示时就不会顿一下
            _ = NSAttributedString(string: "硅基流动 Added “” to Dictionary Thinking Microphone access denied",
                                   attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).size()
            for name in ["sparkle", "exclamationmark.circle.fill"] { _ = NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 72),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: VoiceBarView())
        panel = p
        return p
    }

    func show() {
        onMain {
            let p = self.makePanelIfNeeded()
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 22))
            }
            p.alphaValue = 1
            p.orderFrontRegardless()
            Live.shared.barVisible = true
        }
    }

    func hide() {
        onMain {
            Live.shared.barVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !Live.shared.barVisible { self.panel?.orderOut(nil) }
            }
        }
    }
}

private enum BarState: Hashable {
    case recording, processing, message(String), notice(String), none
}

/// 悬浮条（照着 Typeless 的录屏做的样子和节奏，图形和代码都是自己画的）：
/// 录音：黑色胶囊，左边 ✕、中间左右对称的波形、右边白色 ✓；
/// 结束：按钮淡出，胶囊收窄成只剩波形，再换成灰色的 "Thinking"（带扫光）；文字写进去之后快速淡出。
struct VoiceBarView: View {
    @ObservedObject private var live = Live.shared
    @State private var collapsing = false
    @State private var last: BarState = .none

    private var state: BarState {
        switch live.phase {
        case .recording: return .recording
        case .processing: return .processing
        case .idle:
            if let m = live.barMessage { return .message(m) }
            if let n = live.barNotice { return .notice(n) }
            return .none
        }
    }

    private let height: CGFloat = 36

    var body: some View {
        ZStack(alignment: .bottom) {
            if live.barVisible {
                pill
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)).combined(with: .offset(y: 6)),
                        removal: .opacity))
            }
        }
        .frame(width: 560, height: 72, alignment: .bottom)
        .animation(.easeOut(duration: 0.16), value: live.barVisible)
        .onAppear { last = state }
        .onChange(of: state) { new in
            if new == .processing && last == .recording {
                collapsing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { collapsing = false }
            }
            last = new
        }
    }

    private var isThinking: Bool { state == .processing && !collapsing }

    private var pill: some View {
        content
            .frame(height: height)
            .onHover { live.barHover = $0 }
            .background(Capsule().fill(isThinking ? Color(white: 0.17) : Color.black))
            .overlay(Capsule().stroke(Color(white: isThinking ? 0.27 : 0.22), lineWidth: 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.88), value: state)
            .animation(.spring(response: 0.3, dampingFraction: 0.88), value: collapsing)
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .recording:
            HStack(spacing: 9) {
                BarCircleButton(kind: .cancel) { DictationController.shared.cancel() }
                if live.askMode {
                    Text("Ask").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: 0x58D3A0))
                }
                Waveform().frame(width: 52, height: 24)
                BarCircleButton(kind: .confirm) { DictationController.shared.toggle() }
            }
            .padding(.horizontal, 4.5)
            .transition(.opacity)
        case .processing:
            if collapsing {
                Waveform().frame(width: 52, height: 24)
                    .frame(width: 84)
                    .transition(.opacity)
            } else {
                ShimmerText(text: "Thinking").frame(width: 108)
                    .transition(.opacity)
            }
        case .notice(let n):
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 12)).foregroundColor(Color(hex: 0x58D3A0))
                Text(n).font(.system(size: 13)).foregroundColor(.white.opacity(0.9)).lineLimit(1)
                if live.noticeCanUndo {
                    // 直接在提示条上撤回，不用打开软件去词典里删
                    Button(action: { DictationController.shared.undoNotice() }) {
                        Text("Undo").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.black)
                            .padding(.horizontal, 11).frame(height: 24)
                            .background(Capsule().fill(Color(white: 0.96)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .padding(.leading, 16).padding(.trailing, live.noticeCanUndo ? 6 : 16).fixedSize()
        case .message(let m):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundColor(Color(hex: 0xFFB84D))
                Text(m).font(.system(size: 13)).foregroundColor(.white.opacity(0.9)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 330, alignment: .leading)
                if live.barRetry {
                    Button(action: { DictationController.shared.retryPending() }) {
                        Text("Retry").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.black)
                            .padding(.horizontal, 11).frame(height: 24)
                            .background(Capsule().fill(Color(white: 0.96)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .padding(.leading, 16).padding(.trailing, live.barRetry ? 6 : 16).fixedSize()
        case .none:
            Color.clear.frame(width: 108)
        }
    }
}

/// ✕ 和 ✓ 两个圆按钮
struct BarCircleButton: View {
    enum Kind { case cancel, confirm }
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(kind == .cancel ? Color(white: 0.23) : Color(white: 0.96))
                Path { p in
                    if kind == .cancel {
                        p.move(to: CGPoint(x: 9.8, y: 9.8)); p.addLine(to: CGPoint(x: 17.2, y: 17.2))
                        p.move(to: CGPoint(x: 17.2, y: 9.8)); p.addLine(to: CGPoint(x: 9.8, y: 17.2))
                    } else {
                        p.move(to: CGPoint(x: 8.6, y: 13.9)); p.addLine(to: CGPoint(x: 11.8, y: 17.0)); p.addLine(to: CGPoint(x: 18.4, y: 10.3))
                    }
                }
                .stroke(kind == .cancel ? Color.white : Color.black, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 27, height: 27)
        }
        .buttonStyle(.plain)
    }
}

/// 波形的动画状态：每一帧把各根竖条平滑地推向目标高度（升得快、落得慢），所以 60 帧都是连续的
final class WaveState {
    static let bars = 15
    private var disp = [Double](repeating: 0, count: WaveState.bars)
    private var ring: [Double]
    private var lastPush = 0.0
    private var lastT = 0.0

    init() {
        ring = LevelMeter.shared.preview ?? [Double](repeating: 0, count: 9)
        if let p = LevelMeter.shared.preview { disp = (0..<WaveState.bars).map { p[min(p.count - 1, abs($0 - WaveState.bars / 2))] } }
    }

    func heights(now: Double, level: Double, maxH: Double) -> [Double] {
        let dt = lastT == 0 ? 1.0 / 60 : min(0.05, now - lastT)
        lastT = now
        if LevelMeter.shared.preview == nil, now - lastPush > 0.04 {
            ring.removeLast()
            ring.insert(level, at: 0)
            lastPush = now
        }
        let c = WaveState.bars / 2
        var out = [Double]()
        for i in 0..<WaveState.bars {
            let d = abs(i - c)
            let x = Double(i) / Double(WaveState.bars - 1)
            let envelope = 0.22 + 0.78 * pow(sin(x * Double.pi), 1.4)
            let v = ring[min(ring.count - 1, d)]
            let live = 0.9 + 0.1 * sin(now * 9 + Double(i) * 1.7)
            let target = envelope * min(1, 0.1 + 0.95 * min(1, v * 1.1)) * live
            let tau = target > disp[i] ? 0.035 : 0.14
            disp[i] += (target - disp[i]) * (1 - exp(-dt / tau))
            out.append(max(3, maxH * disp[i]))
        }
        return out
    }
}

struct Waveform: View {
    @State private var state = WaveState()

    var body: some View {
        TimelineView(.animation) { tl in
            let hs = state.heights(now: tl.date.timeIntervalSinceReferenceDate, level: Double(LevelMeter.shared.level), maxH: 18)
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<hs.count, id: \.self) { i in
                    Capsule().fill(Color.white).frame(width: 1.9, height: CGFloat(hs[i]))
                }
            }
        }
    }
}

/// "Thinking"：灰色文字，一道亮光从左扫到右
struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: 1.5)) / 1.5
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.46))
                .overlay(
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, Color(white: 0.92), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.7)
                            .offset(x: -g.size.width * 0.7 + g.size.width * 1.7 * phase)
                    }
                    .mask(Text(text).font(.system(size: 13, weight: .medium)))
                )
        }
    }
}
