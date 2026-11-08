import Foundation

// MARK: - 平台（Provider）和每个用途（识别 / 纠错）各自的模型与参数

enum AuthStyle: String, Codable, CaseIterable {
    case bearer = "Authorization: Bearer <key>"
    case xApiKey = "x-api-key: <key>"
    case none = "No key (local server)"
}

enum NetworkMode: String, Codable, CaseIterable {
    case auto = "Auto"
    case direct = "Direct (no proxy)"
    case system = "System proxy"
}

enum ThinkingMode: String, Codable, CaseIterable {
    case tryDisable = "Try to switch thinking off, fall back if refused"
    case omit = "Don't send any thinking parameter"
    case alwaysOff = "Always send enable_thinking=false"
}

enum ASRProtocol: String, Codable, CaseIterable {
    case transcriptions = "Transcriptions API (/audio/transcriptions)"
    case chatAudio = "Chat model with audio input"
}

enum ChatAudioFormat: String, Codable, CaseIterable {
    case audioURL = "audio_url (SiliconFlow style)"
    case inputAudio = "input_audio (OpenAI style)"
}

enum RoleKind { case asr, correction }
enum ParamMode: String, Codable { case auto, manual }

struct Provider: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var auth: AuthStyle = .bearer
    var network: NetworkMode = .auto
    var chatPath = "/chat/completions"
    var transcriptionPath = "/audio/transcriptions"
    var modelsPath = "/models"
    var extraHeaders = ""          // 每行一个「Name: value」
    var models: [String] = []      // 上次「Fetch models」拉到的模型列表
    var builtin = false
    /// 本机/自建模型：闲置多少分钟后服务器会把它从显存卸掉（0 = 永远不卸）。超过这个时间没用过就算「冷」，
    /// 按下录音键时提前加载，第一次请求的超时也会加长
    var keepAliveMinutes = 5
    /// 冷启动时把模型装进显存要多久（秒）；冷的时候，第一次请求的超时会在平时的基础上再加这么多
    var loadAllowanceSeconds = 120
    /// 可选：服务有「状态/预热」接口时才打开（不是 OpenAI/Ollama 的标准接口，默认关）。
    /// 打开后：按下录音键先 GET 状态路径，返回 JSON 里 loaded=true 且 busy=false 才算就绪；没就绪就 POST 预热路径，再每 2 秒看一次状态。
    var statusAPI = false
    var statusPath = "/health"
    var warmupPath = "/warmup"
    var requiresKey: Bool { auth != .none }
    /// 不要 key 的就当作本机/自建的模型服务（Ollama、LM Studio、自己的服务器）
    var isLocalModel: Bool { auth == .none }

    /// 国内的服务和本机地址默认直连；国外的默认走系统代理
    var isDirectByDefault: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host.hasSuffix(".cn") || host == "localhost" || host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }
    var goesDirect: Bool {
        switch network {
        case .direct: return true
        case .system: return false
        case .auto: return isDirectByDefault
        }
    }
    var hostLabel: String { URL(string: baseURL)?.host ?? baseURL }
}

extension Provider {
    /// 老版本存的 providers.json 里没有新加的字段，缺的用默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        auth = try c.decodeIfPresent(AuthStyle.self, forKey: .auth) ?? .bearer
        network = try c.decodeIfPresent(NetworkMode.self, forKey: .network) ?? .auto
        chatPath = try c.decodeIfPresent(String.self, forKey: .chatPath) ?? "/chat/completions"
        transcriptionPath = try c.decodeIfPresent(String.self, forKey: .transcriptionPath) ?? "/audio/transcriptions"
        modelsPath = try c.decodeIfPresent(String.self, forKey: .modelsPath) ?? "/models"
        extraHeaders = try c.decodeIfPresent(String.self, forKey: .extraHeaders) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        keepAliveMinutes = try c.decodeIfPresent(Int.self, forKey: .keepAliveMinutes) ?? 5
        loadAllowanceSeconds = try c.decodeIfPresent(Int.self, forKey: .loadAllowanceSeconds) ?? 120
        statusAPI = try c.decodeIfPresent(Bool.self, forKey: .statusAPI) ?? false
        statusPath = try c.decodeIfPresent(String.self, forKey: .statusPath) ?? "/health"
        warmupPath = try c.decodeIfPresent(String.self, forKey: .warmupPath) ?? "/warmup"
    }
}

/// 一组请求参数。自动模式下由平台和模型推出来，手动模式下是你自己填的。
struct Params: Codable, Equatable {
    var temperature = 0.0
    var maxTokens = 1500
    var timeout = 40.0
    /// 语音识别的等待时间。timeout 大于 0 就按你填的；等于 0（自动）就按录音长度算：
    /// 一般接口 8 秒 + 每秒录音 0.6 秒，最多 60 秒；音频对话类模型 15 秒 + 每秒录音 1 秒，最多 120 秒。
    /// 本机/自建（不要 key）的识别服务：按实测约 0.55–0.65 秒/秒录音，所以 25 秒 + 每秒录音 1 秒，最多 300 秒。
    func asrTimeout(audioSeconds: Double, local: Bool = false) -> TimeInterval {
        if timeout > 0 { return timeout }
        if local { return min(300, 25 + audioSeconds) }
        return asrProtocol == .chatAudio ? min(120, 15 + audioSeconds) : min(60, 8 + 0.6 * audioSeconds)
    }
    var thinking: ThinkingMode = .tryDisable
    var asrProtocol: ASRProtocol = .transcriptions
    var chatAudioFormat: ChatAudioFormat = .audioURL
    var language = ""                 // 识别：语言提示（zh、en…），空 = 让模型自己判断
    var vocabularyHint = false        // 识别：把词典当作提示词一起发给识别模型（Whisper 一类支持）
    var priceKnown = false
    var priceCurrency = "CNY"         // CNY 或 USD
    var inputPricePerM = 0.0          // 每百万输入 token
    var outputPricePerM = 0.0         // 每百万输出 token
    var audioPricePerSecond = 0.0     // 每秒音频
}

struct RoleConfig: Codable, Equatable {
    var providerId: String
    var model: String
    var mode: ParamMode = .auto
    var manual = Params()
}

// MARK: - 内置的平台预设

struct ProviderPreset {
    let id: String
    let name: String
    let baseURL: String
    let envVar: String
    var auth: AuthStyle = .bearer
    var asrModels: [String] = []
    var correctionModels: [String] = []
    var note = ""
}

enum ProviderCatalog {
    static let presets: [ProviderPreset] = [
        ProviderPreset(id: "siliconflow", name: "SiliconFlow 硅基流动 (China)", baseURL: "https://api.siliconflow.cn/v1", envVar: "SILICONFLOW_API_KEY",
                       asrModels: ["Qwen/Qwen3-ASR-1.7B", "FunAudioLLM/SenseVoiceSmall", "XingChenAGI/XingChenASR-V3.2-Ultra", "XingChenAGI/XingChenASR-V3.2", "Qwen/Qwen3-Omni-30B-A3B-Instruct"],
                       correctionModels: ["deepseek-ai/DeepSeek-V4.1-Flash", "Qwen/Qwen3.5-122B-A10B", "Qwen/Qwen3.5-35B-A3B", "Qwen/Qwen3-30B-A3B-Instruct-2507", "deepseek-ai/DeepSeek-V3.2"],
                       note: "The models below were tested in this app."),
        ProviderPreset(id: "siliconflow-global", name: "SiliconFlow (Global)", baseURL: "https://api.siliconflow.com/v1", envVar: "SILICONFLOW_API_KEY",
                       asrModels: ["Qwen/Qwen3-ASR-1.7B", "FunAudioLLM/SenseVoiceSmall"], correctionModels: ["deepseek-ai/DeepSeek-V4.1-Flash"],
                       note: "A key from siliconflow.com. It is not interchangeable with a siliconflow.cn key."),
        ProviderPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", envVar: "OPENAI_API_KEY",
                       asrModels: ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"], correctionModels: ["gpt-4o-mini", "gpt-4.1-mini"],
                       note: "Not tested here. Use Fetch models to see what your key can use."),
        ProviderPreset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", envVar: "GROQ_API_KEY",
                       asrModels: ["whisper-large-v3-turbo", "whisper-large-v3"], correctionModels: ["llama-3.3-70b-versatile"],
                       note: "Not tested here. Fast Whisper speech recognition."),
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", envVar: "DEEPSEEK_API_KEY",
                       correctionModels: ["deepseek-chat"], note: "Not tested here. Text models only, no speech recognition."),
        ProviderPreset(id: "moonshot", name: "Moonshot Kimi 月之暗面", baseURL: "https://api.moonshot.cn/v1", envVar: "MOONSHOT_API_KEY",
                       note: "Not tested here. Text models only. Use Fetch models."),
        ProviderPreset(id: "zhipu", name: "Zhipu 智谱 BigModel", baseURL: "https://open.bigmodel.cn/api/paas/v4", envVar: "ZHIPUAI_API_KEY",
                       correctionModels: ["glm-4-flash"], note: "Not tested here."),
        ProviderPreset(id: "dashscope", name: "Alibaba DashScope 阿里云百炼", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", envVar: "DASHSCOPE_API_KEY",
                       correctionModels: ["qwen-plus", "qwen-turbo"], note: "Not tested here."),
        ProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", envVar: "OPENROUTER_API_KEY",
                       note: "Not tested here. Text models; pick any chat model id from Fetch models."),
        ProviderPreset(id: "ollama", name: "Ollama (local)", baseURL: "http://127.0.0.1:11434/v1", envVar: "", auth: .none,
                       note: "Runs on this Mac, no key. Use Fetch models to list what you pulled."),
        ProviderPreset(id: "lmstudio", name: "LM Studio (local)", baseURL: "http://127.0.0.1:1234/v1", envVar: "", auth: .none,
                       note: "Runs on this Mac, no key."),
    ]

    static func preset(for id: String) -> ProviderPreset? {
        presets.first { $0.id == id }
            ?? presets.filter { id.hasPrefix($0.id + "-") }.max { $0.id.count < $1.id.count }
    }

    static func make(_ preset: ProviderPreset) -> Provider {
        Provider(id: preset.id, name: preset.name, baseURL: preset.baseURL, auth: preset.auth, builtin: true)
    }

    static func defaultProviders() -> [Provider] { [make(presets[0])] }
}

// MARK: - 参数怎么定：自动 = 由平台和模型推出来；手动 = 用你填的

enum Resolver {
    static func autoParams(kind: RoleKind, provider: Provider, model: String) -> Params {
        var p = Params()
        let m = model.lowercased()
        switch kind {
        case .asr:
            p.timeout = 0   // 0 = 自动：按录音长度算（见 asrTimeout）
            p.maxTokens = 1024
            if m.contains("omni") || m.contains("audio") || m.contains("gpt-4o-audio") {
                p.asrProtocol = .chatAudio
            }
            p.chatAudioFormat = provider.id.hasPrefix("openai") ? .inputAudio : .audioURL
        case .correction:
            p.maxTokens = 1500
            p.timeout = provider.requiresKey ? 40 : 90   // 本机模型比云端慢
        }
        // 价格：只有硅基流动的我们读过定价页，其它平台先标记为"未知"，需要的话在手动模式里填
        if provider.id.hasPrefix("siliconflow") {
            p.priceCurrency = "CNY"
            if let c = Pricing.chat[model] { p.priceKnown = true; p.inputPricePerM = c.input; p.outputPricePerM = c.output }
            else if let s = Pricing.asrPerSecond[model] { p.priceKnown = true; p.audioPricePerSecond = s }
            else if Pricing.freeASR.contains(model) { p.priceKnown = true }
        }
        return p
    }

    static func effective(_ role: RoleConfig, kind: RoleKind, provider: Provider) -> Params {
        role.mode == .manual ? role.manual : autoParams(kind: kind, provider: provider, model: role.model)
    }
}

/// 某一时刻的完整配置快照（后台线程也可以放心用）
struct Setup {
    var settings: AppSettings
    var providers: [Provider]
    func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }
    func role(_ kind: RoleKind) -> RoleConfig { kind == .asr ? settings.asr : settings.correction }
}
