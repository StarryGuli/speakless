import Foundation

// MARK: - 记账：Speakless 每调用一次硅基流动，就记一笔

struct UsageRecord: Codable {
    var ts: Date
    var kind: String          // asr / correct / learn
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var audioSeconds: Double
    var costUsd: Double
    var priced: Bool          // false 表示这个模型我们没有价格，费用按 0 记
    var cachedTokens: Int? = nil   // 这次调用里命中提示词缓存的输入 token 数
    var provider: String? = nil    // 哪个平台（旧记录没有，当作硅基流动）
}

/// 价格来自硅基流动定价页（2026-10-30 读到的），是估算，不是账单。
enum Pricing {
    /// ¥ / 百万 token（输入，输出）
    static let chat: [String: (input: Double, output: Double)] = [
        "deepseek-ai/DeepSeek-V4.1-Flash": (2, 8),
        "deepseek-ai/DeepSeek-V4-Flash": (3, 9),
        "deepseek-ai/DeepSeek-V3.2": (4, 6),
        "Qwen/Qwen3.5-122B-A10B": (0.8, 6.4),
        "Qwen/Qwen3.5-35B-A3B": (0.4, 3.2),
        "Qwen/Qwen3.8-27B": (3, 12),
        "zai-org/GLM-5.3-Flash": (0.8, 2.8),
        "stepfun-ai/Step-3.5-Flash": (0.7, 2.1),
    ]
    /// ¥ / 秒音频
    static let asrPerSecond: [String: Double] = ["Qwen/Qwen3-ASR-1.7B": 0.00022]
    /// 标价为免费的识别模型
    static let freeASR: Set<String> = [
        "FunAudioLLM/SenseVoiceSmall", "XingChenAGI/XingChenASR-V3.2-Ultra", "XingChenAGI/XingChenASR-V3.2",
        "XingChenAGI/XingChenASR-Diarize-V3.0", "XingChenAGI/XingChenGSR-V1.0",
    ]
    /// 没有 token 数的识别模型，按音频每秒约 13 个 token 折算（Qwen3-Omni 文档里的算法），只是为了让图表上有量
    static let audioTokensPerSecond = 13.0

    /// 汇率：优先用 Token Monitor 自己抓的，没有就用 7.2
    static var cnyPerUsd: Double {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Token Monitor/exchange-rates.json")
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rates = obj["rates"] as? [String: Any], let cny = rates["CNY"] as? Double, cny > 1 { return cny }
        return 7.2
    }

    /// 按这次调用实际用的那组参数里的价格算（自动模式下是我们读到的定价，手动模式下是你填的）
    static func cost(params p: Params, provider: String, model: String, input: Int, output: Int, seconds: Double, at date: Date) -> (usd: Double, priced: Bool) {
        guard p.priceKnown else { return (0, false) }
        var native = (Double(input) * p.inputPricePerM + Double(output) * p.outputPricePerM) / 1_000_000 + seconds * p.audioPricePerSecond
        // 硅基流动上的 DeepSeek V4.1 Flash 凌晨 2–8 点半价
        if provider.hasPrefix("siliconflow"), model == "deepseek-ai/DeepSeek-V4.1-Flash", (2..<8).contains(Calendar.current.component(.hour, from: date)) { native *= 0.5 }
        return (p.priceCurrency == "USD" ? native : native / cnyPerUsd, true)
    }
}

final class UsageLog {
    static let shared = UsageLog()
    private let queue = DispatchQueue(label: "speakless.usagelog")
    private let file = AppPaths.support.appendingPathComponent("usage.jsonl")
    private var records: [UsageRecord] = []

    private let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init() {
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            records = text.split(separator: "\n").compactMap { try? dec.decode(UsageRecord.self, from: Data($0.utf8)) }
        }
    }

    func record(kind: String, provider: String, model: String, inputTokens: Int, outputTokens: Int, audioSeconds: Double = 0, cachedTokens: Int = 0, params: Params) {
        if ProcessInfo.processInfo.environment["SPEAKLESS_NO_USAGE"] != nil { return }   // 开发自测时不记账
        let now = Date()
        let c = Pricing.cost(params: params, provider: provider, model: model, input: inputTokens, output: outputTokens, seconds: audioSeconds, at: now)
        let r = UsageRecord(ts: now, kind: kind, model: model, inputTokens: inputTokens, outputTokens: outputTokens,
                            audioSeconds: audioSeconds, costUsd: c.usd, priced: c.priced, cachedTokens: cachedTokens, provider: provider)
        queue.async {
            self.records.append(r)
            if var line = try? self.enc.encode(r) {
                line.append(0x0A)
                if let h = try? FileHandle(forWritingTo: self.file) {
                    h.seekToEndOfFile(); h.write(line); try? h.close()
                } else {
                    try? line.write(to: self.file)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.file.path)
                }
            }
            UsageReporter.shared.noteChange()
            onMain { Live.shared.usageTick &+= 1 }
        }
    }

    func all() -> [UsageRecord] { queue.sync { records } }
}

// MARK: - 上报：把记账结果送给 Token Monitor 的"中心"（POST /api/ingest）

final class UsageReporter {
    static let shared = UsageReporter()

    static let clientId = "siliconflow"
    private let queue = DispatchQueue(label: "speakless.usagereporter")
    private var debounce: DispatchWorkItem?
    private var dirty = true
    private var lastFailed = false
    private var timer: DispatchSourceTimer?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]   // 本机地址，不走任何代理
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    static var secretFile: URL { AppPaths.support.appendingPathComponent("token-monitor-secret") }

    /// 启动时调用：每分钟看一眼，有新用量或者上次没送成就再送一次
    func start() {
        queue.async {
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 5, repeating: 60)
            t.setEventHandler { [weak self] in
                guard let self, self.dirty || self.lastFailed else { return }
                self.send()
            }
            self.timer = t
            t.resume()
        }
    }

    func noteChange() {
        queue.async {
            self.dirty = true
            self.debounce?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.send() }
            self.debounce = w
            self.queue.asyncAfter(deadline: .now() + 4, execute: w)
        }
    }

    func sendNow() { queue.async { self.send() } }

    private func setStatus(_ s: String) { onMain { Live.shared.usageStatus = s } }

    private func send() {
        let (enabled, base) = onMainSync { (AppState.shared.settings.reportToTokenMonitor, AppState.shared.settings.tokenMonitorHubURL) }
        guard enabled else { return setStatus("Reporting is off") }
        guard let url = URL(string: base.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/ingest") else {
            return setStatus("The hub address isn't valid")
        }
        let records = UsageLog.shared.all()
        guard !records.isEmpty else { return setStatus("Nothing to report yet — dictate once first") }

        guard let body = try? JSONSerialization.data(withJSONObject: Self.payload(records: records, now: Date())) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("minimal", forHTTPHeaderField: "x-token-monitor-response")
        if let secret = try? String(contentsOf: Self.secretFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        dirty = false
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
            let time = df.string(from: Date())
            if let http = resp as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    self.lastFailed = false
                    self.setStatus("Sent \(records.count) call\(records.count == 1 ? "" : "s") to Token Monitor at \(time)")
                case 401:
                    self.lastFailed = true; self.dirty = true
                    self.setStatus("Token Monitor says the secret is wrong or missing (401)")
                default:
                    self.lastFailed = true; self.dirty = true
                    let msg = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(120) ?? ""
                    self.setStatus("Token Monitor answered HTTP \(http.statusCode) \(msg)")
                }
            } else {
                self.lastFailed = true; self.dirty = true
                self.setStatus("Can't reach Token Monitor's hub — in Token Monitor turn on Settings → Multi-device Sync → host from this widget")
            }
        }.resume()
        sem.wait()
    }

    // MARK: 把记账结果整理成 Token Monitor 认得的快照

    private struct Acc {
        var tokens = 0, output = 0, unpriced = 0, calls = 0
        var cost = 0.0
        var models: [String: Int] = [:], modelCosts: [String: Double] = [:], modelOutputs: [String: Int] = [:]
        var last = Date.distantPast
    }

    static func shortName(_ model: String) -> String { model.split(separator: "/").last.map(String.init) ?? model }

    static func payload(records: [UsageRecord], now: Date) -> [String: Any] {
        let cal = Calendar.current
        let dayF = DateFormatter(); dayF.dateFormat = "yyyy-MM-dd"; dayF.locale = Locale(identifier: "en_US_POSIX")
        let monF = DateFormatter(); monF.dateFormat = "yyyy-MM"; monF.locale = Locale(identifier: "en_US_POSIX")
        let todayKey = dayF.string(from: now), monthKey = monF.string(from: now)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func fold(_ rs: [UsageRecord]) -> Acc {
            var a = Acc()
            for r in rs {
                var total = r.inputTokens + r.outputTokens
                var out = r.outputTokens
                if total == 0, r.audioSeconds > 0 { total = Int((r.audioSeconds * Pricing.audioTokensPerSecond).rounded()); out = 0 }
                let m = shortName(r.model)
                a.tokens += total; a.output += out; a.cost += r.costUsd; a.calls += 1
                if !r.priced { a.unpriced += total }
                a.models[m, default: 0] += total; a.modelCosts[m, default: 0] += r.costUsd; a.modelOutputs[m, default: 0] += out
                a.last = max(a.last, r.ts)
            }
            return a
        }

        func clientOf(_ r: UsageRecord) -> String { r.provider ?? "siliconflow" }

        // 每个平台在 Token Monitor 里算一个「客户端」，所以同时用了几家平台就会分开显示
        func period(_ rs: [UsageRecord], sessionsBy: (UsageRecord) -> String) -> [String: Any] {
            let a = fold(rs)
            var clients: [String: Int] = [:], clientCosts: [String: Double] = [:], clientOutputs: [String: Int] = [:]
            var clientModels: [String: [String: Int]] = [:], clientModelCosts: [String: [String: Double]] = [:]
            var sessions: [String: Any] = [:]
            for (c, group) in Dictionary(grouping: rs, by: clientOf) {
                let ca = fold(group)
                clients[c] = ca.tokens; clientCosts[c] = ca.cost; clientOutputs[c] = ca.output
                clientModels[c] = ca.models; clientModelCosts[c] = ca.modelCosts
                for (day, g2) in Dictionary(grouping: group, by: sessionsBy) {
                    let s = fold(g2)
                    let id = "speakless-\(day)"
                    sessions["\(c):\(id)"] = [
                        "client": c, "sessionId": id, "totalTokens": s.tokens, "costUsd": s.cost, "messageCount": s.calls,
                        "outputTokens": s.output, "lastUsedAt": iso.string(from: s.last),
                        "models": s.models, "modelCosts": s.modelCosts,
                        "providers": [c: s.tokens],
                    ] as [String: Any]
                }
            }
            return [
                "capabilities": ["tokenComponents": true, "throughput": false],
                "totalTokens": a.tokens, "costUsd": a.cost, "cacheReadTokens": 0, "cacheWriteTokens": 0,
                "outputTokens": a.output, "unclassifiedTokens": 0, "unpricedTokens": a.unpriced,
                "clients": clients, "clientCosts": clientCosts, "clientCacheReads": [String: Int](),
                "clientCacheWrites": [String: Int](), "clientOutputs": clientOutputs,
                "models": a.models, "modelCosts": a.modelCosts, "modelCacheReads": [String: Int](),
                "modelCacheWrites": [String: Int](), "modelOutputs": a.modelOutputs,
                "clientModels": clientModels, "clientModelCosts": clientModelCosts,
                "sessions": sessions, "projects": [String: Any](),
            ]
        }

        let today = records.filter { dayF.string(from: $0.ts) == todayKey }
        let month = records.filter { monF.string(from: $0.ts) == monthKey }
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let endOfMonth = cal.date(byAdding: .month, value: 1, to: cal.dateInterval(of: .month, for: now)?.start ?? now) ?? now
        let host = ProcessInfo.processInfo.hostName.lowercased().replacingOccurrences(of: ".local", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let os = ProcessInfo.processInfo.operatingSystemVersion

        return [
            "deviceId": "speakless-\(host)",
            "hostname": ProcessInfo.processInfo.hostName,
            "platform": "darwin-arm64",
            "osName": "macOS",
            "osVersion": "\(os.majorVersion).\(os.minorVersion)",
            "updatedAt": iso.string(from: now),
            "agentVersion": "0.1.0",
            "agentRuntime": "speakless",
            "syncUploadIntervalMs": 60000,
            "projectsEnabled": false,
            "historyAvailable": false,
            "trackedClients": Array(Set(records.map(clientOf))).sorted(),
            "today": period(today) { dayF.string(from: $0.ts) },
            "month": period(month) { dayF.string(from: $0.ts) },
            "allTime": period(records) { dayF.string(from: $0.ts) },
            "periodWindows": [
                "timeZone": TimeZone.current.identifier,
                "today": ["key": todayKey, "endsAt": iso.string(from: endOfDay)],
                "month": ["key": monthKey, "endsAt": iso.string(from: endOfMonth)],
            ],
        ]
    }
}
