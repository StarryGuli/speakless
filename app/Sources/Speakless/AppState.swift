import SwiftUI
import AppKit
import ServiceManagement

enum Phase { case idle, recording, processing }

/// 听写过程中会频繁变化的状态（阶段、悬浮条是否显示、提示文字）单独放一个对象：
/// 只有悬浮条在看它。以前它们和主界面共用 AppState，每变一次整个主窗口都要重画一遍，就是"卡"的来源。
final class Live: ObservableObject {
    static let shared = Live()
    @Published var phase: Phase = .idle { didSet { HotKeyMonitor.shared.setEscapeArmed(phase != .idle) } }
    @Published var barVisible = false
    @Published var barMessage: String? = nil
    /// 悬浮条上的错误提示要不要带「Retry」按钮（识别失败或超时时，用刚才那段录音重来）
    @Published var barRetry = false
    @Published var barNotice: String? = nil
    @Published var noticeCanUndo = false
    @Published var barHover = false
    /// 这次录音是「问点什么」模式（悬浮条上显示 Ask）
    @Published var askMode = false
    @Published var usageStatus = "Not sent yet"
    @Published var usageTick = 0
}

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", history = "History", dictionary = "Dictionary"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock"
        case .dictionary: return "book"
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case account = "Account", settings = "Settings", models = "Models", personalization = "Personalization", about = "About", help = "Help"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .settings: return "gearshape"
        case .models: return "cpu"
        case .personalization: return "wand.and.stars"
        case .about: return "info.circle"
        case .help: return "questionmark.circle"
        }
    }
}

struct PermissionState: Equatable {
    var microphone = false
    var inputMonitoring = false
    var accessibility = false
}

/// 全局状态。所有 @Published 都只在主线程改。
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            save(settings, "settings.json")
            settingsChanged(old: oldValue)
        }
    }
    @Published var history: [HistoryItem] = [] { didSet { save(history, "history.json") } }
    @Published var dictionary: [DictEntry] = [] { didSet { save(dictionary, "dictionary.json") } }
    @Published var daily: [String: DayStat] = [:] { didSet { save(daily, "stats.json") } }
    @Published var providers: [Provider] = ProviderCatalog.defaultProviders() { didSet { save(providers, "providers.json") } }

    @Published var perms = PermissionState()
    @Published var hasKey = true
    @Published var hotkeyActive = false

    @Published var page: Page = .home
    @Published var showSettings = false
    @Published var settingsPage: SettingsPage = .settings

    private let dir = AppPaths.support
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private var loading = true

    private init() {
        if let s: AppSettings = load("settings.json") { settings = s }
        if let h: [HistoryItem] = load("history.json") { history = h }
        if let d: [DictEntry] = load("dictionary.json") { dictionary = d }
        KeyStore.migrateLegacy()
        if let p: [Provider] = load("providers.json"), !p.isEmpty { providers = p }
        if let s: [String: DayStat] = load("stats.json") { daily = s }
        loading = false
        // 角色指向的平台如果不存在了（比如被删掉），退回到硅基流动
        if !providers.contains(where: { $0.id == "siliconflow" }) { providers.insert(ProviderCatalog.defaultProviders()[0], at: 0) }
        if !providers.contains(where: { $0.id == settings.asr.providerId }) { settings.asr.providerId = "siliconflow" }
        if !providers.contains(where: { $0.id == settings.correction.providerId }) { settings.correction.providerId = "siliconflow" }
        if !settings.dictionarySeeded {
            dictionary = StarterWords.all.map { DictEntry(word: $0) } + dictionary
            settings.dictionarySeeded = true
        }
        pruneHistory()
        refreshPermissions()
    }

    // MARK: 存取

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard !loading, let data = try? encoder.encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    // MARK: 设置的副作用

    private func settingsChanged(old: AppSettings) {
        if old.appearance != settings.appearance { applyAppearance() }
        if old.showInDock != settings.showInDock { applyActivationPolicy() }
        if old.launchAtLogin != settings.launchAtLogin {
            if #available(macOS 13.0, *) {
                do {
                    if settings.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch { NSLog("launch at login failed: \(error)") }
            }
        }
        if old.keepHistory != settings.keepHistory { pruneHistory() }
        HotKeyMonitor.shared.shortcuts = settings.dictateShortcuts
        HotKeyMonitor.shared.askShortcuts = settings.askShortcuts
    }

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applyActivationPolicy() {
        NSApp?.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    // MARK: 权限

    func refreshPermissions() {
        let p = Permissions.current()
        if p != perms { perms = p }
        // @Published 哪怕写入同样的值也会通知界面重画，所以只在真的变了的时候才写
        let k = missingKeyProviders().isEmpty
        if k != hasKey { hasKey = k }
    }

    // MARK: 平台与模型

    func setup() -> Setup { Setup(settings: settings, providers: providers) }

    func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    func providerBinding(_ id: String) -> Binding<Provider> {
        Binding(get: { self.provider(id) ?? Provider(id: id, name: id, baseURL: "") },
                set: { new in if let i = self.providers.firstIndex(where: { $0.id == id }) { self.providers[i] = new } })
    }

    /// 当前需要用到、但还没有 key 的平台（识别一定要用；纠错只有开着才用）
    func missingKeyProviders() -> [Provider] {
        var ids = [settings.asr.providerId]
        if settings.correctionEnabled { ids.append(settings.correction.providerId) }
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let p = provider(id), !KeyStore.hasKey(p) else { return nil }
            return p
        }
    }

    func isInUse(_ providerId: String) -> Bool {
        settings.asr.providerId == providerId || settings.correction.providerId == providerId
    }

    // MARK: 历史与统计

    func pruneHistory() {
        guard let limit = settings.keepHistory.seconds else { return }
        let cutoff = Date().addingTimeInterval(-limit)
        let keep = history.filter { $0.date >= cutoff }
        for gone in history where gone.date < cutoff { removeAudio(gone.id) }
        if keep.count != history.count { history = keep }
    }

    func audioURL(_ id: UUID) -> URL { AppPaths.audio.appendingPathComponent("\(id.uuidString).wav") }
    func removeAudio(_ id: UUID) { try? FileManager.default.removeItem(at: audioURL(id)) }

    func addHistory(_ item: HistoryItem, wav: Data?) {
        let day = Self.dayKey(item.date)
        var stat = daily[day] ?? DayStat()
        stat.words += item.words
        stat.seconds += item.seconds
        daily[day] = stat
        guard settings.keepHistory != .never else { return }
        if let wav { try? wav.write(to: audioURL(item.id)) }
        history.insert(item, at: 0)
    }

    func deleteHistory(_ item: HistoryItem) {
        removeAudio(item.id)
        history.removeAll { $0.id == item.id }
    }

    func deleteAllHistory() {
        history.forEach { removeAudio($0.id) }
        history = []
    }

    // MARK: 词典

    @discardableResult
    func addWord(_ word: String, auto: Bool = false, heardAs: [String] = []) -> DictEntry? {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = heardAs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.lowercased() != w.lowercased() }
        if let i = dictionary.firstIndex(where: { $0.word.lowercased() == w.lowercased() }) {
            // 词已经有了：把新看到的「常被听成」补进去（这正是它一直被听错的原因）
            let merged = Array(Set((dictionary[i].heardAs ?? []) + heard)).sorted()
            if merged != (dictionary[i].heardAs ?? []).sorted() { dictionary[i].heardAs = merged }
            return nil
        }
        guard !w.isEmpty else { return nil }
        let entry = DictEntry(word: w, auto: auto, heardAs: heard.isEmpty ? nil : heard)
        dictionary.insert(entry, at: 0)
        return entry
    }

    /// 发给模型的术语表。有「常被听成」的词写成「词〔常被听成：甲、乙〕」；给语音识别当提示时只取前面的词（见 transcribe）
    var glossary: [String] {
        guard settings.useDictionaryHints else { return [] }
        return dictionary.map { e in
            guard let h = e.heardAs, !h.isEmpty else { return e.word }
            return "\(e.word)〔常被听成：\(h.joined(separator: "、"))〕"
        }
    }

    // MARK: 统计

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func dayKey(_ d: Date) -> String { dayFormatter.string(from: d) }

    var totalWords: Int { daily.values.reduce(0) { $0 + $1.words } }
    var totalSeconds: Double { daily.values.reduce(0) { $0 + $1.seconds } }
    var averageWPM: Int { totalSeconds > 5 ? Int(Double(totalWords) / (totalSeconds / 60)) : 0 }
    /// 按每分钟 45 个词的打字速度估算省下的时间（分钟）
    var minutesSaved: Int { max(0, Int((Double(totalWords) / 45.0) - totalSeconds / 60)) }
    var activeDays: Int { daily.values.filter { $0.words > 0 }.count }

    var streaks: (current: Int, longest: Int) {
        let cal = Calendar.current
        let active = Set(daily.filter { $0.value.words > 0 }.keys)
        var longest = 0, run = 0
        for key in active.sorted() {
            guard let d = Self.parse(key) else { continue }
            let prev = cal.date(byAdding: .day, value: -1, to: d).map(Self.dayKey) ?? ""
            run = active.contains(prev) ? run + 1 : 1
            longest = max(longest, run)
        }
        var current = 0
        var day = Date()
        if !active.contains(Self.dayKey(day)) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        while active.contains(Self.dayKey(day)) {
            current += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return (current, longest)
    }

    static func parse(_ key: String) -> Date? { dayFormatter.date(from: key) }
}

func onMain(_ f: @escaping () -> Void) {
    if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
}
