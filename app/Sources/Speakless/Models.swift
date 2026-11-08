import Foundation
import CoreGraphics

// MARK: - 快捷键

enum HotKeyChoice: String, Codable, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Cmd"
        case .rightControl: return "Right Ctrl"
        }
    }
    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }
    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        }
    }
}

enum ClipboardMode: String, Codable, CaseIterable {
    case always = "Always keep the text on the clipboard"
    case slow = "Only when it takes longer than the time below"
    case never = "Never (put back what was on the clipboard)"
}

enum Appearance: String, Codable, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"
}

enum KeepHistory: String, Codable, CaseIterable {
    case forever = "Forever", year = "1 year", month = "1 month", week = "1 week", day = "24 hours", never = "Never"

    var seconds: TimeInterval? {
        switch self {
        case .forever: return nil
        case .year: return 365 * 86400
        case .month: return 30 * 86400
        case .week: return 7 * 86400
        case .day: return 86400
        case .never: return 0
        }
    }
}

// MARK: - 模型目录

struct ModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let note: String
    let tag: String?
}

enum ModelCatalog {
    static let defaultASR = "Qwen/Qwen3-ASR-1.7B"
    static let defaultCorrector = "deepseek-ai/DeepSeek-V4.1-Flash"

    // 2026-10-30 在 3 段真实录音上实测的结果
    static let asr: [ModelOption] = [
        ModelOption(id: "Qwen/Qwen3-ASR-1.7B", title: "Qwen3-ASR 1.7B",
                    note: "Fastest and most accurate in our tests, about 1 s. Paid: ¥0.00022 per second of audio.", tag: "Recommended"),
        ModelOption(id: "FunAudioLLM/SenseVoiceSmall", title: "SenseVoice Small",
                    note: "Free and fast, but more wrong characters.", tag: "Free"),
        ModelOption(id: "XingChenAGI/XingChenASR-V3.2-Ultra", title: "XingChen ASR V3.2 Ultra",
                    note: "Free, 3–5 s. Often mishears terms like “环境变量”.", tag: "Free"),
        ModelOption(id: "XingChenAGI/XingChenASR-V3.2", title: "XingChen ASR V3.2",
                    note: "Free, similar to Ultra and a little faster.", tag: "Free"),
        ModelOption(id: "Qwen/Qwen3-Omni-30B-A3B-Instruct", title: "Qwen3-Omni 30B Instruct",
                    note: "Fluent, but can change the meaning of a sentence. Billed by tokens.", tag: nil),
    ]

    static let correctors: [ModelOption] = [
        ModelOption(id: "deepseek-ai/DeepSeek-V4.1-Flash", title: "DeepSeek V4.1 Flash",
                    note: "Lowest error rate in our tests, about 1.3 s. ¥2 / ¥8 per million tokens.", tag: "Recommended"),
        ModelOption(id: "Qwen/Qwen3.5-122B-A10B", title: "Qwen3.5 122B A10B",
                    note: "Nearly as accurate and cheaper (¥0.8 / ¥6.4). Sometimes leans too hard on the dictionary.", tag: "Cheaper"),
        ModelOption(id: "Qwen/Qwen3.5-35B-A3B", title: "Qwen3.5 35B A3B",
                    note: "Cheapest good option (¥0.4 / ¥3.2), about 3 s.", tag: nil),
        ModelOption(id: "Qwen/Qwen3-30B-A3B-Instruct-2507", title: "Qwen3 30B A3B Instruct",
                    note: "Fast, less accurate on mixed Chinese and English.", tag: nil),
        ModelOption(id: "deepseek-ai/DeepSeek-V3.2", title: "DeepSeek V3.2",
                    note: "Accurate but slow (6–7 s), not great for dictation.", tag: nil),
    ]

    static func title(for id: String, in list: [ModelOption]) -> String {
        list.first(where: { $0.id == id })?.title ?? (id.split(separator: "/").last.map(String.init) ?? id)
    }
}

// MARK: - 设置

private struct LegacyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct AppSettings: Codable, Equatable {
    /// 语音识别和纠错各用各的「平台 + 模型 + 参数」
    var asr = RoleConfig(providerId: "siliconflow", model: ModelCatalog.defaultASR)
    var correction = RoleConfig(providerId: "siliconflow", model: ModelCatalog.defaultCorrector)
    var asrModel: String { get { asr.model } set { asr.model = newValue } }
    var correctorModel: String { get { correction.model } set { correction.model = newValue } }
    var correctionEnabled = true
    var correctionTimeout = 5.0
    /// 整理的等待时间：你设的秒数 + 按文字长度加的（每个字 0.06 秒，最多加 15 秒）。话越长，模型越要写得久
    /// 本机/自建模型的整理更慢：底线 10 秒，每个字 0.1 秒，最多加 30 秒（这组数是估的，没有实测）
    func correctionWait(forChars n: Int, local: Bool = false) -> Double {
        local ? max(correctionTimeout, 10) + min(30, Double(n) * 0.1) : correctionTimeout + min(15, Double(n) * 0.06)
    }
    var dictateShortcuts: [Shortcut] = [Shortcut(codes: [63])]
    /// 「问点什么」：按 Fn+空格开始说，再按一次结束
    var askShortcuts: [Shortcut] = [Shortcut(codes: [63, 49])]
    /// 场景信息：开始录音时读取当前软件的这些内容，交给整理模型（默认全开，和 Typeless 一致）
    var contextWindow = true         // 窗口标题、网页标题和域名
    var contextInputType = true      // 输入框类型（代码编辑器/普通文本框）、是否支持 Markdown
    var contextCursorText = true     // 光标前后的文字
    var contextSelected = true       // 已选中的文字
    var contextScreen = true         // 窗口里能看到的文字
    /// 「问点什么」遇到需要最新信息的问题时，先联网搜一次（只发搜索关键词）
    var askWebSearch = true
    var contextBlockedApps: [String] = []   // 这些软件（名字或 bundle id）不采集任何场景信息
    var interfaceLanguage = "English (US)"
    var translationTargets = ["English (US)"]
    var microphoneUID: String? = nil
    var interactionSounds = true
    var clipboardMode: ClipboardMode = .always
    var clipboardSlowSeconds = 0.5
    var soundStyle: SoundStyle = .soft
    var muteWhenDictating = true
    /// 边说边识别（只对本机/自建识别模型生效）和触发它的停顿秒数
    var streamWhileSpeaking = true
    var streamPauseSeconds = 2.0
    var streamStartAfterSeconds = 15.0   // 整段录音超过这么多秒才开始切，更短的全部整段识别
    var appearance: Appearance = .system
    var launchAtLogin = false
    var showInDock = false
    var keepHistory: KeepHistory = .forever
    var customInstructions = ""
    var correctionPrompt = DefaultPrompts.polish
    var useDictionaryHints = true
    var learnFromCorrections = true
    var reportToTokenMonitor = true
    var tokenMonitorHubURL = "http://127.0.0.1:17321"
    var dictionarySeeded = false

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 旧版本只存了两个模型名（都属于硅基流动）
        let legacy = try decoder.container(keyedBy: LegacyKey.self)
        if let old = try legacy.decodeIfPresent(String.self, forKey: LegacyKey("asrModel")) { asr.model = old }
        if let old = try legacy.decodeIfPresent(String.self, forKey: LegacyKey("correctorModel")) { correction.model = old }
        asr = try c.decodeIfPresent(RoleConfig.self, forKey: .asr) ?? asr
        correction = try c.decodeIfPresent(RoleConfig.self, forKey: .correction) ?? correction
        correctionEnabled = try c.decodeIfPresent(Bool.self, forKey: .correctionEnabled) ?? correctionEnabled
        correctionTimeout = try c.decodeIfPresent(Double.self, forKey: .correctionTimeout) ?? correctionTimeout
        if let new = try c.decodeIfPresent([Shortcut].self, forKey: .dictateShortcuts) {
            dictateShortcuts = new
        } else {
            // 旧版本存的是单个修饰键的列表
            let legacy = try decoder.container(keyedBy: LegacyKey.self)
            if let old = try legacy.decodeIfPresent([HotKeyChoice].self, forKey: LegacyKey("dictateKeys")), !old.isEmpty {
                dictateShortcuts = old.map { Shortcut(codes: [$0.keyCode]) }
            }
        }
        askShortcuts = try c.decodeIfPresent([Shortcut].self, forKey: .askShortcuts) ?? askShortcuts
        contextWindow = try c.decodeIfPresent(Bool.self, forKey: .contextWindow) ?? contextWindow
        contextInputType = try c.decodeIfPresent(Bool.self, forKey: .contextInputType) ?? contextInputType
        contextCursorText = try c.decodeIfPresent(Bool.self, forKey: .contextCursorText) ?? contextCursorText
        contextSelected = try c.decodeIfPresent(Bool.self, forKey: .contextSelected) ?? contextSelected
        contextScreen = try c.decodeIfPresent(Bool.self, forKey: .contextScreen) ?? contextScreen
        askWebSearch = try c.decodeIfPresent(Bool.self, forKey: .askWebSearch) ?? askWebSearch
        contextBlockedApps = try c.decodeIfPresent([String].self, forKey: .contextBlockedApps) ?? contextBlockedApps
        interfaceLanguage = try c.decodeIfPresent(String.self, forKey: .interfaceLanguage) ?? interfaceLanguage
        translationTargets = try c.decodeIfPresent([String].self, forKey: .translationTargets) ?? translationTargets
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID)
        interactionSounds = try c.decodeIfPresent(Bool.self, forKey: .interactionSounds) ?? interactionSounds
        clipboardMode = try c.decodeIfPresent(ClipboardMode.self, forKey: .clipboardMode) ?? clipboardMode
        clipboardSlowSeconds = try c.decodeIfPresent(Double.self, forKey: .clipboardSlowSeconds) ?? clipboardSlowSeconds
        soundStyle = try c.decodeIfPresent(SoundStyle.self, forKey: .soundStyle) ?? soundStyle
        muteWhenDictating = try c.decodeIfPresent(Bool.self, forKey: .muteWhenDictating) ?? muteWhenDictating
        streamWhileSpeaking = try c.decodeIfPresent(Bool.self, forKey: .streamWhileSpeaking) ?? streamWhileSpeaking
        streamPauseSeconds = try c.decodeIfPresent(Double.self, forKey: .streamPauseSeconds) ?? streamPauseSeconds
        streamStartAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .streamStartAfterSeconds) ?? streamStartAfterSeconds
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? appearance
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? showInDock
        keepHistory = try c.decodeIfPresent(KeepHistory.self, forKey: .keepHistory) ?? keepHistory
        customInstructions = try c.decodeIfPresent(String.self, forKey: .customInstructions) ?? customInstructions
        if let stored = try c.decodeIfPresent(String.self, forKey: .correctionPrompt) {
            correctionPrompt = DefaultPrompts.isUntouchedOldDefault(stored) ? DefaultPrompts.polish : stored
        }
        useDictionaryHints = try c.decodeIfPresent(Bool.self, forKey: .useDictionaryHints) ?? useDictionaryHints
        learnFromCorrections = try c.decodeIfPresent(Bool.self, forKey: .learnFromCorrections) ?? learnFromCorrections
        reportToTokenMonitor = try c.decodeIfPresent(Bool.self, forKey: .reportToTokenMonitor) ?? reportToTokenMonitor
        tokenMonitorHubURL = try c.decodeIfPresent(String.self, forKey: .tokenMonitorHubURL) ?? tokenMonitorHubURL
        dictionarySeeded = try c.decodeIfPresent(Bool.self, forKey: .dictionarySeeded) ?? dictionarySeeded
    }
}

// MARK: - 初始词典（第一次启动时放进词典，可以随便删改）

enum StarterWords {
    /// 通用的技术词，新用户第一次打开时放进词典。个人的名字和术语请自己加（或让自动学习来加）。
    static let all = [
        "SiliconFlow", "Qwen", "DeepSeek", "API Key", "token", "cookie", ".zshrc",
        "Claude Code", "GitHub", "Python", "React", "async", "requests", "httpx",
        "nginx", "SSH", "WebSocket", "VPS", "Tailscale", "ESP32", "PlatformIO", "macOS",
    ]
}

// MARK: - 数据

enum HistoryKind: String, Codable { case dictation = "Dictations", ask = "Ask anything" }

struct HistoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var kind: HistoryKind = .dictation
    var appName = ""
    var raw = ""
    var text = ""
    var asrModel = ""
    var asrProvider: String? = nil
    var correctorProvider: String? = nil
    var correctorModel: String? = nil
    var asrMs = 0
    var correctionMs = 0
    /// 识别每一段各用了多久（毫秒）；整段一次识别的只有一项
    var segmentsMs: [Int]? = nil
    /// 这次录音期间把本机模型装进显存用了多久（毫秒），没发生过就是空
    var loadMs: Int? = nil
    var asrProviderName: String? = nil
    var correctorProviderName: String? = nil
    var asrLocal: Bool? = nil
    var correctorLocal: Bool? = nil
    var seconds = 0.0
    var words = 0
    var note: String? = nil
}

struct DictEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var word: String
    var auto = false
    var added = Date()
    /// 这个词常被识别成什么（比如「扑动」常被听成「普通」）。整理模型会照这个把听错的写法改回来
    var heardAs: [String]? = nil
}

struct DayStat: Codable, Equatable {
    var words = 0
    var seconds = 0.0
}

func countWords(_ s: String) -> Int {
    var cjk = 0
    for u in s.unicodeScalars {
        let v = u.value
        if (0x4E00...0x9FFF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) { cjk += 1 }
    }
    var latin = 0
    if let re = try? NSRegularExpression(pattern: "[A-Za-z0-9][A-Za-z0-9'’_\\-.]*") {
        latin = re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }
    return cjk + latin
}
