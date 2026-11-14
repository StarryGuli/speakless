import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Speakless", isDirectory: true)
        // 开发用：指向另一个数据目录（比如做截图时用演示数据，不碰真实记录）
        if let o = ProcessInfo.processInfo.environment["SPEAKLESS_SUPPORT_DIR"], !o.isEmpty { dir = URL(fileURLWithPath: o, isDirectory: true) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let audio: URL = {
        let dir = support.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// 每个平台的 API key 各存一个只有你自己能读的文件（0600）：~/Library/Application Support/Speakless/keys/<平台id>
/// 不进 git，也只会发给那个平台自己的地址。
enum KeyStore {
    static var dir: URL {
        let d = AppPaths.support.appendingPathComponent("keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func file(_ id: String) -> URL { dir.appendingPathComponent(id) }

    static func load(_ p: Provider) -> String? {
        guard p.requiresKey else { return nil }
        if let s = try? String(contentsOf: file(p.id), encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let env = ProviderCatalog.preset(for: p.id)?.envVar, !env.isEmpty,
           let e = ProcessInfo.processInfo.environment[env], !e.isEmpty { return e }
        return nil
    }

    static func hasKey(_ p: Provider) -> Bool { !p.requiresKey || load(p) != nil }

    static func save(_ key: String, for id: String) throws {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try t.write(to: file(id), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id).path)
    }

    static func clear(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }

    /// 从 ~/.zshrc 里找 `export 变量名="..."`
    static func importFromZshrc(envVar: String) -> String? {
        guard !envVar.isEmpty else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: envVar) + "\\s*=\\s*[\"']?([A-Za-z0-9_\\-.]{16,})[\"']?") else { return nil }
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func masked(_ k: String) -> String {
        guard k.count > 10 else { return String(repeating: "•", count: k.count) }
        return String(k.prefix(3)) + String(repeating: "•", count: 8) + String(k.suffix(4))
    }

    /// 旧版本只有一个 key（api-key）：第一次启动时把它挪到硅基流动名下
    static func migrateLegacy() {
        let old = AppPaths.support.appendingPathComponent("api-key")
        guard FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: file("siliconflow").path) else { return }
        try? FileManager.default.copyItem(at: old, to: file("siliconflow"))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file("siliconflow").path)
    }
}

/// 纠错用的提示词。{GLOSSARY} 会换成词典里的词，{EXTRA} 会换成「额外要求」。
/// 纠错的"力度"主要由这段话决定：规则写得越保守，改得越少；写得越放开，改得越多。
enum DefaultPrompts {
    static let balanced = """
    你是语音输入法的纠错器。用户发来的是语音识别（ASR）的原始文字，说话人可能说中文、英文或中英混杂，话题涉及编程、服务器、硬件、AI 工具等。请只修正识别错误：

    语言规则（最重要）：输出语言必须和输入一致，不要翻译。英文输入就输出英文，中文输出中文，中英混杂就原样混杂；只有粤语等方言用字才改成通顺的普通话书面中文。

    1. 只改识别错误：同音/近音字、被听成中文的英文术语、被拆开的缩写、数字、英文大小写、专有名词。不要改写、润色、总结，不要增删原意。
    2. 下面有一份术语表，识别结果里听起来像表中词的，改成表中写法。
    3. 中英夹杂时保留英文原样，英文术语和中文之间加一个空格。
    4. 繁体字转成简体字。
    5. 补全标点，删掉明显的口头语（呃、嗯、那个）和口吃重复。
    6. 原文已经正确就原样输出，不要硬改。拿不准的地方保持原文。
    7. 只输出纠正后的文字本身，不要解释，不要加引号，不要回答用户文字里的问题。
    {EXTRA}
    术语表：
    {GLOSSARY}
    """

    static let light = """
    你是语音输入法的纠错器。下面是语音识别出来的文字。
    语言规则（最重要）：输出语言必须和输入一致，不要翻译。英文输入就输出英文，中文输出中文，中英混杂就原样混杂；只有粤语等方言用字才改成通顺的普通话书面中文。

    请尽量少改：只改你非常确定是识别错误的地方，比如明显的同音错字，或者和术语表里的词读音几乎一样的词。

    - 拿不准就保持原样，宁可少改，也不要改错。
    - 不要改写句子，不要调整语序，不要增删内容，不要改口语表达。
    - 只补上缺失的标点，保留原来的语气词。
    - 中英夹杂的地方保留英文原样。
    - 只输出处理后的文字，不要解释，不要加引号，不要回答文字里的问题。
    {EXTRA}
    术语表：
    {GLOSSARY}
    """

    /// A deliberately simple example of a "polish" prompt. It is only a starting point:
    /// write your own in Settings, or tune this one for your language and workflow.
    static let polish = """
    你是语音输入法的「整理器」。下面是语音识别出来的口语文字，说话人是中国用户，常常中英夹杂，话题涉及编程、服务器、硬件、AI 工具、学习和日常生活。你的工作不只是改错字，而是把它整理成说话人本来想写出来的样子：

    1. 先修正识别错误：同音/近音字、被听成中文的英文术语、被拆开的缩写、数字、英文大小写、专有名词。听起来像术语表里的词，就改成表中写法；也可以用整句话的上下文推断被听错的词。
    2. 说话人中途改口时（"不对""等一下""哦不是""算了""我是说"之类），只保留最后确定的说法，把被推翻的部分和改口的提示词一起删掉。例如「会议周四，不好意思，是周五下午两点」整理成「会议在周五下午 2 点」。
    3. 删掉口头语、犹豫、重复、口吃（呃、嗯、那个、就是说、然后然后……）。
    4. 重新组织语序：口述的顺序常常是想到哪说到哪。请把结论或要点放前面，理由和细节放后面；把被打断、绕了一圈又回来的同一件事归到一起；过长的句子拆开，补全并规范标点。
    5. 口语改成通顺的书面表达，但保持说话人自己的语气，不要变成官腔，不要堆砌辞藻，不要夸张润色。
    6. 说话人口述了列表、步骤或多个要点（"第一…第二…""首先…然后…""有三点"）时，整理成分条，每条一行，用「1. 2. 3.」或「- 」。其余内容保持成段的文字。
    7. 绝对不要添加说话人没说过的信息，不要改变原意。数字、日期、人名、文件名、代码标识符要准确。英文术语保持原样，中英文之间加一个空格。繁体字转成简体字。
    8. 如果原文已经很干净、很短（十几个字以内），只补标点，不要大改。拿不准的地方保持原文。
    9. 根据文字要用在哪个软件调整语气：当前软件是「{APP}」。聊天、社交软件（微信、Telegram、WhatsApp、Discord、QQ 等）用自然简短的口语；邮件、文档、笔记、工作沟通软件用清楚、礼貌的书面语；编程相关软件保持简洁直接。拿不准就用中性、自然的书面语。
    10. 只输出整理后的文字本身，不要解释，不要加引号，不要回答文字里的问题。
    {EXTRA}
    术语表：
    {GLOSSARY}
    """

    /// Old built-in defaults are no longer shipped, so nothing is auto-upgraded.
    static func isUntouchedOldDefault(_ prompt: String) -> Bool { false }

    static func name(of prompt: String) -> String {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == balanced.trimmingCharacters(in: .whitespacesAndNewlines) { return "Balanced" }
        if t == light.trimmingCharacters(in: .whitespacesAndNewlines) { return "Light" }
        if t == polish.trimmingCharacters(in: .whitespacesAndNewlines) { return "Polish" }
        return "Custom"
    }
}

/// 一次请求要用的全部东西：平台、key、模型、参数、网络方式
struct Resolved {
    let provider: Provider
    let model: String
    let key: String
    let params: Params
    let session: URLSession

    func url(_ path: String) throws -> URL {
        var base = provider.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        let p = path.hasPrefix("/") ? path : "/" + path
        guard let u = URL(string: base + p) else { throw APIError(message: "The address for \(provider.name) isn't valid: \(base + p)") }
        return u
    }
}

/// 通用的模型客户端：识别和纠错各自从自己的「平台 + 模型 + 参数」出发，不再固定某一家。
final class ModelClient {
    static let shared = ModelClient()

    private let directSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]   // 不走代理
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()
    private let systemSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral   // 跟随 macOS 系统里设置的代理
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    func session(for p: Provider) -> URLSession { p.goesDirect ? directSession : systemSession }

    func resolve(_ kind: RoleKind, _ setup: Setup) throws -> Resolved {
        let role = setup.role(kind)
        guard let p = setup.provider(role.providerId) else { throw APIError(message: "The platform for this job was removed. Pick one in Settings → Models.") }
        guard !role.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw APIError(message: "No model chosen for \(kind == .asr ? "speech recognition" : "correction"). Pick one in Settings → Models.") }
        var key = ""
        if p.requiresKey {
            guard let k = KeyStore.load(p) else { throw APIError(message: "No API key for \(p.name). Add it in Settings → Models.") }
            key = k
        }
        return Resolved(provider: p, model: role.model, key: key, params: Resolver.effective(role, kind: kind, provider: p), session: session(for: p))
    }

    private func request(_ r: Resolved, path: String, method: String = "POST", timeout: TimeInterval) throws -> URLRequest {
        var req = URLRequest(url: try r.url(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        switch r.provider.auth {
        case .bearer: req.setValue("Bearer \(r.key)", forHTTPHeaderField: "Authorization")
        case .xApiKey: req.setValue(r.key, forHTTPHeaderField: "x-api-key")
        case .none: break
        }
        for line in r.provider.extraHeaders.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { req.setValue(parts[1], forHTTPHeaderField: parts[0]) }
        }
        return req
    }

    private func send(_ req: URLRequest, _ r: Resolved) async throws -> Data {
        let (data, resp) = try await r.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "No response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError(message: "HTTP \(http.statusCode): \(body.prefix(200))")
        }
        return data
    }

    // MARK: 识别

    /// 本机模型第一次被叫到时要从磁盘装进显存（实测约 100 秒），所以这个 App 会话里第一次请求某个本机服务时多等 120 秒
    /// 「热」= 这个模型最近一次成功用过距今不到「闲置卸载时间」（在 Models 里按平台设）。
    /// 最后一次使用的时间存在磁盘上，重开 App 不会被当成冷的；真的隔了很久没用才算冷。
    private static let warmLock = NSLock()
    private static let warmStore = "speakless.lastModelUse"
    private func warmKey(_ r: Resolved, _ role: String) -> String { "\(r.provider.id)|\(r.model)|\(role)" }
    private func isWarm(_ r: Resolved, _ role: String) -> Bool {
        if r.provider.keepAliveMinutes <= 0 { return true }   // 设成永不卸载
        Self.warmLock.lock(); defer { Self.warmLock.unlock() }
        let d = UserDefaults.standard.dictionary(forKey: Self.warmStore) as? [String: Double] ?? [:]
        guard let t = d[warmKey(r, role)] else { return false }
        return Date().timeIntervalSince1970 - t < Double(r.provider.keepAliveMinutes) * 60
    }
    private func asrWait(_ r: Resolved, _ seconds: Double) -> TimeInterval {
        let base = r.params.asrTimeout(audioSeconds: seconds, local: r.provider.isLocalModel)
        guard r.provider.isLocalModel, r.params.timeout <= 0 else { return base }
        return isWarm(r, "asr") ? base : base + Double(r.provider.loadAllowanceSeconds)
    }
    private func markWarm(_ r: Resolved, _ role: String = "asr") {
        guard r.provider.isLocalModel else { return }
        Self.warmLock.lock(); defer { Self.warmLock.unlock() }
        var d = UserDefaults.standard.dictionary(forKey: Self.warmStore) as? [String: Double] ?? [:]
        d[warmKey(r, role)] = Date().timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: Self.warmStore)
    }

    /// 预热用的一小段真人说话声（macOS 自带的 say 合成，缓存在本地）。不能用静音：很多识别服务对静音直接跳过，根本不会装载模型。
    private static let warmupWav: Data? = {
        let url = AppPaths.support.appendingPathComponent("warmup.wav")
        if let d = try? Data(contentsOf: url), d.count > 40000 { return d }
        // 先用中文语音（Tingting），没有的话用系统默认语音念英文；结果太短（<1.2 秒）说明这个语音念不出来，换下一个
        let attempts: [(voice: String?, text: String)] = [("Tingting", "你好，今天天气不错，我们开始吧。"), (nil, "Hello, the weather is nice today, let us begin.")]
        for at in attempts {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = (at.voice.map { ["-v", $0] } ?? []) + ["-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", at.text]
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { continue }
            if let d = try? Data(contentsOf: url), d.count > 40000 { return d }
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }()

    /// 一按下录音键就调用：本机/自建的识别和整理模型如果是「冷」的（闲置超过它的卸载时间），先发一个最小的请求把它们装进显存，
    /// 这样说完话时模型已经就绪。云端平台直接跳过。失败了不报错（写进录音日志），真正的请求会再试。
    /// 这次录音期间，本机模型装载花了多久（毫秒）。预热结束时写入，写进历史记录后清掉
    private var loadMsStore: Int? = nil
    private func setLoadMs(_ ms: Int) { Self.warmLock.lock(); loadMsStore = ms; Self.warmLock.unlock() }
    func takeLoadMs() -> Int? { Self.warmLock.lock(); defer { Self.warmLock.unlock() }; let v = loadMsStore; loadMsStore = nil; return v }

    func prewarm(setup: Setup) {
        Self.warmLock.lock(); loadMsStore = nil; Self.warmLock.unlock()
        for kind in [RoleKind.asr, .correction] {
            guard let r = try? resolve(kind, setup), r.provider.isLocalModel else { continue }
            let role = kind == .asr ? "asr" : "correction"
            let warmGuess = isWarm(r, role)
            Task.detached(priority: .utility) { [self] in
                let t0 = Date()
                do {
                    if kind == .asr {
                        // 服务自带状态接口（GET /health 里有 loaded、POST /warmup 立即返回并在后台装模型）就直接问它，比猜时间、发假音频可靠
                        if r.provider.statusAPI, await self.serverWarmup(r) { return }
                    }
                    if warmGuess { RecLog.write("prewarm \(role): \(r.model) was used recently, skipped"); return }
                    RecLog.write("prewarm \(role): \(r.model) is cold, loading it now")
                    if kind == .asr {
                        let wav = Self.warmupWav ?? Recorder.wav(from: [Float](repeating: 0, count: 16000))
                        let text = try await self.transcribe(wav: wav, setup: setup, warmup: true)
                        RecLog.write(String(format: "prewarm asr: done in %.1f s, heard “%@”", Date().timeIntervalSince(t0), text))
                        self.setLoadMs(Int(Date().timeIntervalSince(t0) * 1000))
                    } else {
                        let payload: [String: Any] = ["model": r.model, "messages": [["role": "user", "content": "hi"]], "max_tokens": 1, "stream": false]
                        _ = try await self.chat(payload, r, kind: "warmup", timeout: 180)
                        self.markWarm(r, "correction")
                        RecLog.write(String(format: "prewarm correction: done in %.1f s", Date().timeIntervalSince(t0)))
                    }
                } catch { RecLog.write("prewarm \(role) failed: \(error.localizedDescription)") }
            }
        }
    }

    /// 站点根地址（去掉末尾的 /v1），状态接口在这里
    private func originRequest(_ r: Resolved, _ path: String, method: String, timeout: TimeInterval) -> URLRequest? {
        var base = r.provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
        guard let url = URL(string: base + (path.hasPrefix("/") ? path : "/" + path)) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        return req
    }

    /// 问服务的 /health 和 /warmup。实测这个服务：POST /warmup 后 loaded 立刻变 true，但模型还在往显存里装（约 100 秒），
    /// 期间 busy 是 true；装完 busy 才变 false。所以「就绪」= loaded 且不忙。
    /// 服务没有这个接口（或不是这种格式）返回 false，由调用方退回「发一小段说话声」的办法。
    private func serverWarmup(_ r: Resolved) async -> Bool {
        let t0 = Date()
        func health() async -> (loaded: Bool, busy: Bool)? {
            guard let req = originRequest(r, r.provider.statusPath, method: "GET", timeout: 8),
                  let (data, resp) = try? await r.session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let loaded = j["loaded"] as? Bool else { return nil }
            return (loaded, j["busy"] as? Bool ?? false)
        }
        guard let h0 = await health() else { RecLog.write("prewarm asr: no status reply at \(r.provider.statusPath), using a short speech clip instead"); return false }
        if h0.loaded && !h0.busy { markWarm(r); RecLog.write("prewarm asr: server says the model is already loaded and idle"); return true }
        if !h0.loaded {
            guard let wreq = originRequest(r, r.provider.warmupPath, method: "POST", timeout: 15),
                  let (_, wresp) = try? await r.session.data(for: wreq), (wresp as? HTTPURLResponse)?.statusCode == 200 else {
                RecLog.write("prewarm asr: POST \(r.provider.warmupPath) failed, using a short speech clip instead"); return false
            }
            RecLog.write("prewarm asr: model not loaded, asked the server to load it (POST \(r.provider.warmupPath))")
        } else {
            RecLog.write("prewarm asr: server is busy (loading or recognising), waiting for it")
        }
        let limit = Double(max(60, r.provider.loadAllowanceSeconds + 60))
        while Date().timeIntervalSince(t0) < limit {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let h = await health(), h.loaded, !h.busy {
                markWarm(r)
                RecLog.write(String(format: "prewarm asr: model ready after %.0f s", Date().timeIntervalSince(t0)))
                setLoadMs(Int(Date().timeIntervalSince(t0) * 1000))
                return true
            }
        }
        RecLog.write("prewarm asr: model not ready after \(Int(limit)) s")
        return true
    }

    func transcribe(wav: Data, setup: Setup, glossary: [String] = [], warmup: Bool = false) async throws -> String {
        let r = try resolve(.asr, setup)
        let seconds = Double(max(0, wav.count - 44)) / 32000
        if r.params.asrProtocol == .chatAudio {
            let audio: [String: Any]
            let b64 = wav.base64EncodedString()
            switch r.params.chatAudioFormat {
            case .audioURL: audio = ["type": "audio_url", "audio_url": ["url": "data:audio/wav;base64," + b64]]
            case .inputAudio: audio = ["type": "input_audio", "input_audio": ["data": b64, "format": "wav"]]
            }
            let payload: [String: Any] = [
                "model": r.model,
                "messages": [["role": "user", "content": [audio, ["type": "text", "text": "请逐字转写这段音频里的人声内容，只输出转写出的文字，不要解释，不要加任何前后缀。"]]]],
                "max_tokens": r.params.maxTokens,
                "stream": false,
            ]
            let text = try await chat(payload, r, kind: warmup ? "warmup" : "asr", timeout: warmup ? 180 : asrWait(r, seconds))
            markWarm(r)
            return text
        }

        let boundary = UUID().uuidString
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        func field(_ name: String, _ value: String) { add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n") }
        field("model", r.model)
        if !r.params.language.isEmpty { field("language", r.params.language) }
        if r.params.vocabularyHint, !glossary.isEmpty { field("prompt", Array(Set(glossary.map { String($0.split(separator: "〔").first ?? "") })).sorted().prefix(40).joined(separator: ", ")) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"rec.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n--\(boundary)--\r\n")

        var req = try request(r, path: r.provider.transcriptionPath, timeout: warmup ? 180 : asrWait(r, seconds))
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let data = try await send(req, r)
        markWarm(r)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["text"] as? String else {
            throw APIError(message: "Unexpected recognition response")
        }
        if !warmup { UsageLog.shared.record(kind: "asr", provider: r.provider.id, model: r.model, inputTokens: 0, outputTokens: 0, audioSeconds: seconds, params: r.params) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 纠错

    func correct(text: String, glossary: [String], extra: String, prompt: String = "", appName: String = "", context: AppContext? = nil, setup: Setup) async throws -> String {
        let r = try resolve(.correction, setup)
        // 词表按固定顺序排好：新增一个词只会改动词表那一小段，前面的长提示词保持不变，缓存才命中得了
        var gloss = glossary.isEmpty ? "（空）" : Array(Set(glossary)).sorted().joined(separator: "\n")
        if glossary.contains(where: { $0.contains("〔") }) {
            // 「词〔常被听成：甲〕」= 语音识别总把这个词听成甲。原文里出现甲、而且上下文说得通，就必须改回前面的词，
            // 哪怕甲本身是个常见词（比如把「普通」改回「扑动」）；上下文明显是甲本来的意思时才保持原样
            gloss = "（写了「常被听成」的词：原文里出现那个听错的写法、而且放在句子里讲得通时，一律改成前面的词，哪怕听错的写法本身是个常见词；只有上下文明确就是它本来的意思时才保持原样）\n" + gloss
        }
        let extraBlock = extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n用户的额外要求：\(extra)\n"
        var template = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DefaultPrompts.balanced : prompt
        // 用户自己写的提示词里如果没放占位符，就把术语表和额外要求接在最后
        if !template.contains("{GLOSSARY}") { template += "\n\n术语表：\n{GLOSSARY}" }
        if !template.contains("{EXTRA}") { template += "\n{EXTRA}" }
        let system = template.replacingOccurrences(of: "{GLOSSARY}", with: gloss).replacingOccurrences(of: "{EXTRA}", with: extraBlock)
            .replacingOccurrences(of: "{APP}", with: appName.isEmpty ? "未知" : appName)
        // 场景信息接在最后（放在前面的长提示词和词表之后，前面的部分才不会因为每次场景不同而缓存不命中）
        let ctx = context?.promptBlock() ?? ""
        let fullSystem = ctx.isEmpty ? system : system + "\n\n" + ctx
        let payload: [String: Any] = [
            "model": r.model,
            "messages": [["role": "system", "content": fullSystem], ["role": "user", "content": text]],
            "temperature": r.params.temperature,
            "max_tokens": r.params.maxTokens,
            "stream": false,
        ]
        let out = try await chatWithThinking(payload, r, kind: "correct", timeout: r.params.timeout)
        markWarm(r, "correction")
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”\n "))
    }

    struct Answer { var text: String; var sources: [SearchHit]; var query: String? }

    /// 「问点什么」：说出来的话是一个问题，答案显示在回答框里（不粘贴、不替换任何文字）。
    /// 模型觉得需要最新信息时只回一行「SEARCH: 关键词」，这边去搜一次网页，再把结果交给它回答。
    func answer(question: String, glossary: [String], context: AppContext, search: Bool, setup: Setup,
                onStatus: @escaping (String) -> Void = { _ in }) async throws -> Answer {
        let r = try resolve(.correction, setup)
        let day = DateFormatter(); day.locale = Locale(identifier: "zh_CN"); day.dateFormat = "yyyy年M月d日 EEEE"
        var rules = """
        你是用户的语音问答助手。用户是对着麦克风说话的，「问题」是语音识别出来的文字，可能有同音错字，按意思理解。今天是\(day.string(from: Date()))。
        你的回答会显示在一个小的回答框里：
        1. 直接回答：先给结论，再给必要的解释。不要开场白（「好的」「当然」），不要复述问题。
        2. 简洁：三五句能说清就不要长篇；需要步骤或对比时才分点。可以用 Markdown（加粗、列表、代码块），不要用标题。
        3. 语言跟随问题的语言。
        4. 场景信息里的「已选中的文字」「窗口里能看到的文字」可能是问题指的对象，比如「这是什么意思」「帮我看看这个报错」；问题没有指它们就不用管。
        5. 不确定的事就说不确定，不要编。
        """
        if search {
            rules += "\n6. 如果问题需要最新信息、具体数据、新闻、价格，或者你不确定的事实：只输出一行「SEARCH: 搜索关键词」，不要输出别的（关键词要精炼；中文问题用中文，查英文资料用英文）。你能直接答好的问题不要搜索。"
        }
        var system = rules
        if !glossary.isEmpty { system += "\n\n术语表（这些词的写法以此为准）：\n" + Array(Set(glossary)).sorted().joined(separator: "\n") }
        let ctx = context.promptBlock(forAsk: true)
        if !ctx.isEmpty { system += "\n\n" + ctx }

        func call(_ system: String, _ user: String) async throws -> String {
            let payload: [String: Any] = [
                "model": r.model,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                "temperature": 0.3,
                "max_tokens": max(r.params.maxTokens, 1500),
                "stream": false,
            ]
            return try await chatWithThinking(payload, r, kind: "correct", timeout: max(r.params.timeout, 60))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        onStatus("Thinking")
        let first = try await call(system, "问题：" + question)
        markWarm(r, "correction")
        let line = first.split(separator: "\n").first.map(String.init) ?? ""
        guard search, line.uppercased().hasPrefix("SEARCH:") || line.uppercased().hasPrefix("SEARCH：") else {
            return Answer(text: first, sources: [], query: nil)
        }
        let query = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        onStatus("Searching the web: \(query)")
        let hits = (try? await WebSearch.search(query)) ?? []
        onStatus("Reading the results")
        var user = "问题：" + question
        if hits.isEmpty {
            user += "\n\n（联网搜索没有拿到结果。请只凭你确定知道的内容回答，并说明没有查到最新信息。）"
        } else {
            user += "\n\n联网搜索结果（关键词：\(query)）：\n" + hits.enumerated().map { "[\($0.offset + 1)] \($0.element.title)\n\($0.element.url)\n\($0.element.snippet)" }.joined(separator: "\n\n")
            user += "\n\n请依据这些结果和你确定知道的内容回答；用到哪条就在句末标 [1]、[2]；结果里没有答案就直说没查到，不要编。不要再输出 SEARCH。"
        }
        let second = try await call(rules.replacingOccurrences(of: "\n6.", with: "\n（已联网）"), user)
        return Answer(text: second, sources: hits, query: query)
    }

    /// 按你选的「思考参数」方式发请求
    private func chatWithThinking(_ payload: [String: Any], _ r: Resolved, kind: String, timeout: TimeInterval) async throws -> String {
        switch r.params.thinking {
        case .omit:
            return try await chat(payload, r, kind: kind, timeout: timeout)
        case .alwaysOff:
            var p = payload; p["enable_thinking"] = false
            return try await chat(p, r, kind: kind, timeout: timeout)
        case .tryDisable:
            // 先关思考模式（语音输入等不起）；不认这个参数的平台会返回 400，去掉后重试
            do {
                var p = payload; p["enable_thinking"] = false
                return try await chat(p, r, kind: kind, timeout: timeout)
            } catch let e as APIError where e.message.hasPrefix("HTTP 400") {
                return try await chat(payload, r, kind: kind, timeout: timeout)
            }
        }
    }

    private func chat(_ payload: [String: Any], _ r: Resolved, kind: String, timeout: TimeInterval) async throws -> String {
        var req = try request(r, path: r.provider.chatPath, timeout: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await send(req, r)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw APIError(message: "Unexpected chat response")
        }
        // 接口返回的 usage 是精确的 token 数，记一笔账
        if kind != "warmup", let u = obj["usage"] as? [String: Any] {
            func n(_ k: String) -> Int { (u[k] as? Int) ?? Int((u[k] as? Double) ?? 0) }
            var cached = n("prompt_cache_hit_tokens")
            if cached == 0, let d = u["prompt_tokens_details"] as? [String: Any] { cached = (d["cached_tokens"] as? Int) ?? 0 }
            UsageLog.shared.record(kind: kind, provider: r.provider.id, model: r.model, inputTokens: n("prompt_tokens"), outputTokens: n("completion_tokens"), cachedTokens: cached, params: r.params)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 用户把识别出来的 old 手改成了 new：这是不是在纠正专有词？是的话返回改对之后的词（用「纠错」那一路的平台和模型）
    func extractTerms(old: String, new: String, context: String, setup: Setup) async throws -> [String] {
        let r = try resolve(.correction, setup)
        let prompt = """
        语音识别出了「\(old)」，用户手动把它改成了「\(new)」。改动处附近的上下文：「\(context)」。
        判断这次修改是不是在纠正一个专有词：人名、产品名、公司名、术语、缩写、英文单词。
        如果是，只输出「改对之后的那个词本身」：
        - 必须包含被改的部分，但不要把旁边没被改的词一起带进来（比如上下文里还有别的词，不要加进去）；
        - 英文名字只要名字本身，不要加前后的词；最长 3 个英文单词或 10 个汉字。
        如果只是改普通词语、换说法、改语法、改标点，输出空数组。
        只输出一个 JSON 数组，例如 ["Speakless"]，最多 1 个词，不要输出别的。
        """
        let payload: [String: Any] = ["model": r.model, "messages": [["role": "user", "content": prompt]], "temperature": 0, "max_tokens": 120, "stream": false]
        let out = try await chatWithThinking(payload, r, kind: "learn", timeout: min(20, r.params.timeout))
        guard let l = out.firstIndex(of: "["), let rr = out.lastIndex(of: "]"), l < rr,
              let data = String(out[l...rr]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return Array(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3))
    }

    // MARK: 平台：检查 key 和拉取模型列表（只读，不产生费用）

    func fetchModels(provider p: Provider) async throws -> [String] {
        var key = ""
        if p.requiresKey {
            guard let k = KeyStore.load(p) else { throw APIError(message: "No API key saved for \(p.name) yet.") }
            key = k
        }
        let r = Resolved(provider: p, model: "", key: key, params: Params(), session: session(for: p))
        let req = try request(r, path: p.modelsPath, method: "GET", timeout: 15)
        let data = try await send(req, r)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let arr = obj["data"] as? [[String: Any]] else {
            throw APIError(message: "Connected, but the model list wasn't in the usual format.")
        }
        return arr.compactMap { $0["id"] as? String }.sorted()
    }
}

func withTimeout<T>(_ seconds: Double, _ op: @escaping () async throws -> T) async -> Result<T, Error> {
    await withTaskGroup(of: Result<T, Error>.self) { group in
        group.addTask {
            do { return .success(try await op()) } catch { return .failure(error) }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return .failure(APIError(message: "Correction timed out after \(Int(seconds)) s"))
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}
