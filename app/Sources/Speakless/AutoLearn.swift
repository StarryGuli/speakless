import AppKit
import ApplicationServices

/// 听写粘贴之后的一小段时间里，盯着光标所在的输入框：
/// 如果你把刚写进去的那段话里某个词改了，就把改对的词学进 Dictionary（Auto-added）。
///
/// 它靠 macOS 的「辅助功能」去读别的软件里的输入框文字，所以只有「把输入框文字交出来」的软件才行：
/// 备忘录、文本编辑、Safari、大多数原生软件都可以；Electron / 网页类（Claude 桌面版、VS Code 等）要先打开它们的辅助功能开关，
/// 我们会自动请求一次；微信这类自己画界面的软件通常读不到。每一步结果都写在「Learning log」里，方便你看卡在哪。
///
/// 隐私：只读当前获得焦点的那个输入框，只在内存里比较；密码框一律跳过；
/// 只有「改动的那一小段」会发给纠错模型判断是不是专有词；日志里只有改动的那几个词和原因，存在本机。
/// 性能：读别的软件的输入框要走系统的跨进程调用，对方卡一下我们就跟着卡，所以全部放在后台线程。
final class AutoLearn {
    static let shared = AutoLearn()

    private let queue = DispatchQueue(label: "speakless.autolearn", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var element: AXUIElement?
    private var inserted = ""
    private var v0 = ""
    private var lastSeen = ""
    private var lastGood: String?
    private var lastChange = Date()
    private var startedAt = Date()
    private var generation = 0
    private var learnSetup: Setup?
    private var appName = ""
    private var pid: pid_t = 0

    // MARK: 日志（只存最近 120 行）

    static var logURL: URL { AppPaths.support.appendingPathComponent("autolearn.log") }
    private static let logLock = NSLock()

    static func log(_ message: String) {
        logLock.lock(); defer { logLock.unlock() }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
        var lines = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        lines.append("\(f.string(from: Date()))  \(message)")
        if lines.count > 120 { lines.removeFirst(lines.count - 120) }
        try? (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }
    static func readLog() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
    static func clearLog() { try? FileManager.default.removeItem(at: logURL) }

    // MARK: 开始 / 取消

    /// 在文字粘贴完之后调用（主线程）
    func begin(inserted text: String, appName: String, pid: pid_t) {
        let enabled = AppState.shared.settings.learnFromCorrections
        let setup = AppState.shared.setup()
        queue.async {
            self.stopLocked()
            guard enabled else { return }
            guard AXIsProcessTrusted() else { Self.log("skipped: Accessibility isn't allowed for Speakless"); return }
            self.generation += 1
            self.learnSetup = setup
            self.appName = appName
            self.pid = pid
            self.attempt(0, text: text, gen: self.generation)
        }
    }

    func cancel() {
        queue.async {
            self.generation += 1
            self.stopLocked()
        }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        element = nil
    }

    // MARK: 找到输入框并读到里面的文字（读不到就再试几次）

    private enum Inspect { case ready(AXUIElement, String), retry(String), stop(String) }

    private func inspect(_ text: String) -> Inspect {
        guard let el = Self.focused(pid: pid) else { return .retry("no focused text field found") }
        if Self.isSecure(el) { return .stop("password field, skipped") }
        let role = Self.attr(el, kAXRoleAttribute) ?? "?"
        guard let v = Self.value(el) else { return .retry("this app doesn't hand over the text of its input box (role \(role))") }
        guard v.count < 50_000 else { return .stop("field is too large") }
        guard Self.locate(text, in: v) != nil else { return .retry("the text you dictated isn't in the focused box (role \(role))") }
        return .ready(el, v)
    }

    private func attempt(_ n: Int, text: String, gen: Int) {
        guard gen == generation else { return }
        let delays = [0.5, 0.7, 1.0, 1.4, 2.0]
        switch inspect(text) {
        case .ready(let el, let v):
            element = el; inserted = text; v0 = v; lastSeen = v; lastGood = nil
            lastChange = Date(); startedAt = Date()
            Self.log("watching \(appName): \(text.count) characters, box has \(v.count)")
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.25, repeating: 0.25)
            t.setEventHandler { [weak self] in self?.tick(gen: gen) }
            timer = t
            t.resume()
        case .stop(let why):
            Self.log("\(appName): \(why)")
        case .retry(let why):
            if n == 0 {
                // Electron / Chromium 类软件默认不对外提供输入框内容，要对它发一个开关
                Self.enableManualAccessibility(pid: pid)
                Self.log("\(appName): \(why) — asked the app to expose its text fields, retrying")
            }
            if n < delays.count {
                queue.asyncAfter(deadline: .now() + delays[n]) { self.attempt(n + 1, text: text, gen: gen) }
            } else {
                Self.log("\(appName): gave up — \(why)")
            }
        }
    }

    // MARK: 盯着输入框

    private func tick(gen: Int) {
        guard gen == generation, let el = element else { return stopLocked() }
        let cur = Self.focused(pid: pid)
        guard let cur, CFEqual(cur, el), let v = Self.value(el) else { return finalize("you left the box", gen: gen) }
        if v != lastSeen {
            lastSeen = v
            lastChange = Date()
            // 记下「改过、而且还像是同一段文字」的最近一版；之后输入框被清空（发送）也还能拿它来比
            if v != v0 && v.count * 3 >= v0.count { lastGood = v }
        }
        if v.count * 3 < v0.count, lastGood != nil { return finalize("the box was cleared (message sent?)", gen: gen) }
        if let g = lastGood, g != v0, Date().timeIntervalSince(lastChange) > 1.5, v == g { return finalize("edit settled", gen: gen) }
        if Date().timeIntervalSince(startedAt) > 40 { finalize("40 seconds passed", gen: gen) }
    }

    private func finalize(_ reason: String, gen: Int) {
        guard gen == generation else { return }
        stopLocked()
        if let g = lastGood, g != v0 { evaluate(g, reason: reason) }
        else { Self.log("\(appName): no edit to the dictated text was seen (\(reason))") }
    }

    private func evaluate(_ v: String, reason: String) {
        guard let setup = learnSetup else { return }
        let a = Array(v0), b = Array(v)
        var p = 0
        while p < min(a.count, b.count), a[p] == b[p] { p += 1 }
        var s = 0
        while s < min(a.count, b.count) - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let oldMid = String(a[p..<(a.count - s)])
        let newMid = String(b[p..<(b.count - s)])
        guard !oldMid.isEmpty, !newMid.isEmpty else { return Self.log("\(appName): edit was only an insertion or a deletion, not a correction") }
        guard oldMid.count <= 400, newMid.count <= 400 else { return Self.log("\(appName): edit too large (\(oldMid.count)→\(newMid.count) chars)") }

        // 改动必须落在刚才写进去的那段文字里，改别处的不算
        guard let r = Self.locate(inserted, in: v0) else { return Self.log("\(appName): couldn't locate the dictated text") }
        let tStart = v0.distance(from: v0.startIndex, to: r.lowerBound)
        let tEnd = v0.distance(from: v0.startIndex, to: r.upperBound)
        guard p >= tStart, a.count - s <= tEnd else { return Self.log("\(appName): you edited text outside what was just dictated, ignored") }

        let found = Self.hunks(old: Self.tokenize(oldMid), new: Self.tokenize(newMid))
            .filter { !$0.old.isEmpty && !$0.new.isEmpty && $0.old.count <= 8 && $0.new.count <= 8 }
            .filter { h in h.new.contains(where: { $0.contains(where: { $0.isLetter || $0.isNumber }) }) }
            .prefix(3)
        guard !found.isEmpty else { return Self.log("\(appName): edit found (\(reason)) but no word-level replacement in it") }
        Self.log("\(appName): edit found (\(reason)): " + found.map { "“\(Self.join($0.old))”→“\(Self.join($0.new))”" }.joined(separator: ", "))

        Task {
            var learned: [(word: String, heard: String)] = []
            for h in found {
                let newText = Self.join(h.new)
                let terms: [String]
                do { terms = try await ModelClient.shared.extractTerms(old: Self.join(h.old), new: newText, context: h.context, setup: setup) }
                catch { Self.log("model check failed: \(error.localizedDescription.prefix(80))"); continue }
                if terms.isEmpty { Self.log("model: “\(newText)” is not a name/term worth keeping"); continue }
                for t in terms {
                    if let why = Self.validate(term: t, changed: newText, context: h.context) { Self.log("rejected “\(t)”: \(why)"); continue }
                    learned.append((t, Self.join(h.old)))
                }
            }
            guard !learned.isEmpty else { return }
            onMain {
                var added: [DictEntry] = []
                for (w, heard) in learned {
                    if let e = AppState.shared.addWord(w, auto: true, heardAs: [heard]) { added.append(e); Self.log("added “\(w)” to the dictionary (often heard as “\(heard)”)") }
                    else { Self.log("“\(w)” is already in the dictionary — remembered it is often heard as “\(heard)”") }
                }
                guard !added.isEmpty else { return }
                let names = added.map { "“\($0.word)”" }.joined(separator: " ")
                DictationController.shared.notice("Added \(names) to Dictionary", undo: {
                    let ids = Set(added.map { $0.id })
                    AppState.shared.dictionary.removeAll { ids.contains($0.id) }
                })
            }
        }
    }

    // MARK: 分词和比对

    /// 英文单词（含数字和 . _ - '）算一个词，中文每个字算一个，标点单独算
    static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let joiners: Set<Character> = [".", "_", "-", "'", "’"]
        func flush() {
            guard !cur.isEmpty else { return }
            var word = cur
            var tail: [Character] = []
            while let l = word.last, joiners.contains(l) { tail.insert(l, at: 0); word.removeLast() }
            if !word.isEmpty { out.append(word) }
            tail.forEach { out.append(String($0)) }
            cur = ""
        }
        for ch in text {
            if ch.isWhitespace { flush(); continue }
            if ch.isASCII && (ch.isLetter || ch.isNumber || (joiners.contains(ch) && !cur.isEmpty)) { cur.append(ch) }
            else { flush(); out.append(String(ch)) }
        }
        flush()
        return out
    }

    static func join(_ tokens: [String]) -> String {
        var s = ""
        for (i, t) in tokens.enumerated() {
            if i > 0, (tokens[i - 1].last?.isASCII ?? false), (t.first?.isASCII ?? false),
               (tokens[i - 1].last?.isLetter ?? false || tokens[i - 1].last?.isNumber ?? false) { s += " " }
            s += t
        }
        return s
    }

    struct Hunk { var old: [String]; var new: [String]; var context: String }

    /// 最长公共子序列比对，返回每一处连续的改动
    static func hunks(old a: [String], new b: [String]) -> [Hunk] {
        var p = 0
        while p < min(a.count, b.count), a[p] == b[p] { p += 1 }
        var s = 0
        while s < min(a.count, b.count) - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let A = Array(a[p..<(a.count - s)]), B = Array(b[p..<(b.count - s)])
        guard A.count <= 150, B.count <= 150 else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: B.count + 1), count: A.count + 1)
        for i in stride(from: A.count - 1, through: 0, by: -1) {
            for j in stride(from: B.count - 1, through: 0, by: -1) {
                dp[i][j] = A[i] == B[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [Hunk] = []
        var curOld: [String] = [], curNew: [String] = []
        var startJ = 0
        func close(endJ: Int) {
            guard !curOld.isEmpty || !curNew.isEmpty else { return }
            let lo = max(0, p + startJ - 6), hi = min(b.count, p + endJ + 6)
            out.append(Hunk(old: curOld, new: curNew, context: join(Array(b[lo..<hi]))))
            curOld = []; curNew = []
        }
        var i = 0, j = 0
        while i < A.count || j < B.count {
            if i < A.count, j < B.count, A[i] == B[j] { close(endJ: j); i += 1; j += 1 }
            else if j < B.count, (i == A.count || dp[i][j + 1] >= dp[i + 1][j]) {
                if curOld.isEmpty && curNew.isEmpty { startJ = j }
                curNew.append(B[j]); j += 1
            } else {
                if curOld.isEmpty && curNew.isEmpty { startJ = j }
                curOld.append(A[i]); i += 1
            }
        }
        close(endJ: j)
        return out
    }

    /// 模型给的词是不是靠谱：在上下文里真的出现过、包含被改的部分，并且不能把旁边没改的词也带进来
    static func valid(term: String, changed: String, context: String) -> Bool { validate(term: term, changed: changed, context: context) == nil }

    /// nil = 通过；否则返回为什么不通过
    static func validate(term: String, changed: String, context: String) -> String? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...24).contains(t.count) else { return "length not 2–24" }
        guard context.contains(t) else { return "not in the surrounding text" }
        let tl = t.lowercased(), cl = changed.lowercased()
        // 必须包含被改的部分（英文整词、或中文被改的那几个字）
        guard tl.contains(cl) else { return "doesn't contain the part you changed" }
        // 英文：多出来的部分不能含有别的英文单词。「Speakless macbook starry」里 macbook、starry 没被改，所以不行
        let extraLatin = Set(tokenize(t).filter { $0.first?.isASCII == true && $0.contains(where: \.isLetter) }.map { $0.lowercased() })
            .subtracting(Set(tokenize(changed).map { $0.lowercased() }))
        if !extraLatin.isEmpty { return "also contains words you didn't change (\(extraLatin.sorted().joined(separator: ", ")))" }
        // 中文：词最多 10 个字，并且被改的字至少占一半左右（避免把一大段话整个收进去）
        let han = t.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        if han > 10 { return "too long (over 10 Chinese characters)" }
        if han > 0 {
            let changedHan = changed.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
            if changedHan * 3 < han { return "mostly unchanged text around your edit" }
        }
        return nil
    }

    // MARK: 辅助功能接口

    /// 找出当前获得焦点的输入框：先问系统，不行再直接问那个软件
    private static func focused(pid: pid_t) -> AXUIElement? {
        func ask(_ root: AXUIElement) -> AXUIElement? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v else { return nil }
            return (v as! AXUIElement)
        }
        return ask(AXUIElementCreateSystemWide()) ?? (pid > 0 ? ask(AXUIElementCreateApplication(pid)) : nil)
    }

    /// 给 Electron / Chromium 类软件发「请把输入框内容交出来」的开关
    static func enableManualAccessibility(pid: pid_t) {
        guard pid > 0 else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// 在输入框文字里找到刚才写进去的那一段。有些软件会稍微改动文字（空格、换行），所以找不到整段时，用开头和结尾各一小段来定位
    static func locate(_ inserted: String, in v: String) -> Range<String.Index>? {
        if let r = v.range(of: inserted) { return r }
        guard inserted.count >= 12 else { return nil }
        let head = String(inserted.prefix(6)), tail = String(inserted.suffix(6))
        guard let h = v.range(of: head), let t = v.range(of: tail, range: h.upperBound..<v.endIndex) else { return nil }
        return h.lowerBound..<t.upperBound
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func isSecure(_ el: AXUIElement) -> Bool {
        for attr in [kAXRoleAttribute, kAXSubroleAttribute] {
            if let s = Self.attr(el, attr), s.contains("Secure") { return true }
        }
        return false
    }

    private static func value(_ el: AXUIElement) -> String? { attr(el, kAXValueAttribute) }
}
