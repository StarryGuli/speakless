import SwiftUI
import AppKit

// MARK: - 按键名字

enum KeyNames {
    static let names: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Esc",
        // 日语键盘多出来的键
        93: "¥", 94: "_", 95: "JIS ,", 102: "Eisu 英数", 104: "Kana かな",
        54: "Right Cmd", 55: "Left Cmd", 56: "Left Shift", 57: "Caps Lock", 58: "Left Option", 59: "Left Ctrl",
        60: "Right Shift", 61: "Right Option", 62: "Right Ctrl", 63: "Fn",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// 修饰键和它对应的标志位（左右同类共用一个标志位）
    static let cgFlags: [Int64: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand, 56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate, 59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn,
    ]
    static func nsFlag(_ c: Int64) -> NSEvent.ModifierFlags? {
        switch c {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }

    static func isModifier(_ c: Int64) -> Bool { cgFlags[c] != nil }
    static func name(_ c: Int64) -> String { names[c] ?? "Key \(c)" }

    /// 功能键可以单独当快捷键用，字母、空格这类不行
    static let standalone: Set<Int64> = [102, 104, 64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122]

    private static let rank: [Int64: Int] = [63: 0, 59: 1, 62: 2, 58: 3, 61: 4, 56: 5, 60: 6, 55: 7, 54: 8]
    static func sorted(_ codes: Set<Int64>) -> [Int64] {
        codes.sorted { a, b in
            let ra = rank[a] ?? 100, rb = rank[b] ?? 100
            return ra != rb ? ra < rb : a < b
        }
    }
}

/// 一个快捷键 = 同时按住的 1 到 3 个键
struct Shortcut: Codable, Equatable, Hashable {
    var codes: [Int64]

    init(codes: [Int64]) { self.codes = KeyNames.sorted(Set(codes)) }

    var labels: [String] { codes.map(KeyNames.name) }
    /// 只有一个修饰键（比如单按 Fn）：按下再松开算一次
    var isSingleModifier: Bool { codes.count == 1 && KeyNames.isModifier(codes[0]) }
    var hasPlainKey: Bool { codes.contains(where: { !KeyNames.isModifier($0) }) }
}

// MARK: - 全局监听（组合键：所有键同时按住时触发）

/// 监听放在自己的线程里，主线程再忙也不会让按键延迟或被系统掐掉
final class HotKeyMonitor {
    static let shared = HotKeyMonitor()

    var shortcuts: [Shortcut] = [Shortcut(codes: [63])] { didSet { resetState() } }
    var onFire: (() -> Void)?
    /// 「问点什么」的快捷键和触发回调
    var askShortcuts: [Shortcut] = [] { didSet { resetState() } }
    var onFireAsk: (() -> Void)?
    private func fire(_ sc: Shortcut?) {
        let ask = sc.map { s in askShortcuts.contains(s) && !shortcuts.contains(s) } ?? false
        DispatchQueue.main.async { [weak self] in if ask { self?.onFireAsk?() } else { self?.onFire?() } }
    }
    /// 按 Esc 中断听写。只有在录音或处理中（armed）才拦下这个键，平时 Esc 照常交给当前 App
    var onEscape: (() -> Void)?
    private var escapeArmed = false
    func setEscapeArmed(_ on: Bool) { lock.lock(); escapeArmed = on; lock.unlock() }
    /// 录快捷键的时候要暂停，免得一按键就触发听写
    var paused = false { didSet { resetState() } }

    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    /// true 表示用的是能拦截按键的监听（需要「辅助功能」权限），组合里的普通键不会被打到当前 App 里
    private(set) var canSwallow = false

    private let lock = NSLock()
    private var held = Set<Int64>()
    private var tapStart: [Int64: Date] = [:]
    private var tapCancelled = false
    private var fired = Set<Shortcut>()
    private var swallowKeys = Set<Int64>()

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        let info = Unmanaged.passUnretained(self).toOpaque()
        var t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                  eventsOfInterest: mask, callback: callback, userInfo: info)
        canSwallow = t != nil
        if t == nil {
            t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                  eventsOfInterest: mask, callback: callback, userInfo: info)
        }
        guard let created = t else { return false }
        tap = created
        resetState()

        let thread = Thread { [weak self] in
            guard let self else { return }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            CFRunLoopRun()
        }
        thread.name = "speakless.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// 授权了「辅助功能」之后，从只听不拦升级成能拦截的监听
    func upgradeIfPossible() {
        guard let t = tap, !canSwallow, AXIsProcessTrusted() else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        if let rl = tapRunLoop { CFRunLoopStop(rl) }
        tap = nil
        tapRunLoop = nil
        start()
    }

    private func resetState() {
        lock.lock(); defer { lock.unlock() }
        held = []; tapStart = [:]; tapCancelled = false; fired = []; swallowKeys = []
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            resetState()
            return false
        }
        if paused { return false }
        lock.lock(); defer { lock.unlock() }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .flagsChanged:
            guard let myFlag = KeyNames.cgFlags[code] else { return false }
            let flags = event.flags
            // 某一类修饰键的标志位已经全没了，说明中间漏过事件，把它们从"按住"里清掉
            for (c, f) in KeyNames.cgFlags where !flags.contains(f) { held.remove(c) }
            if flags.contains(myFlag) && !held.contains(code) { return down(code, isModifier: true) }
            return up(code)
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return canSwallow && swallowKeys.contains(code) }
            // Esc：听写进行中就中断它（不带任何修饰键时才算）
            if code == 53, escapeArmed, held.isEmpty,
               event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
                swallowKeys.insert(code)
                DispatchQueue.main.async { [weak self] in self?.onEscape?() }
                return canSwallow
            }
            return down(code, isModifier: false)
        case .keyUp:
            return up(code)
        default:
            return false
        }
    }

    // 下面两个只在已经拿到 lock 的情况下调用
    private func down(_ code: Int64, isModifier: Bool) -> Bool {
        held.insert(code)
        if held.count > 1 { tapCancelled = true }
        if isModifier, held.count == 1, (shortcuts + askShortcuts).contains(where: { $0.isSingleModifier && $0.codes[0] == code }) {
            tapStart[code] = Date()
            tapCancelled = false
        }
        var swallow = false
        for sc in shortcuts + askShortcuts where !sc.isSingleModifier && Set(sc.codes) == held && !fired.contains(sc) {
            fired.insert(sc)
            if !isModifier { swallowKeys.insert(code); swallow = canSwallow }
            fire(sc)
        }
        return swallow
    }

    private func up(_ code: Int64) -> Bool {
        held.remove(code)
        if let t = tapStart.removeValue(forKey: code) {
            if !tapCancelled && held.isEmpty && Date().timeIntervalSince(t) < 2 {
                fire((shortcuts + askShortcuts).first { $0.isSingleModifier && $0.codes[0] == code })
            }
        }
        fired = fired.filter { !$0.codes.contains(code) }
        return swallowKeys.remove(code) != nil && canSwallow
    }
}

// MARK: - 录入快捷键（点一下输入框，然后把想要的键一起按下去）

final class ShortcutRecorder: ObservableObject {
    @Published var held: [Int64] = []
    @Published var message: String? = nil

    private var monitor: Any?
    private var cur = Set<Int64>()
    private var peak = Set<Int64>()
    private var onDone: ((Shortcut?) -> Void)?

    func start(onDone: @escaping (Shortcut?) -> Void) {
        stop()
        self.onDone = onDone
        message = nil; cur = []; peak = []; held = []
        HotKeyMonitor.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            self?.handle(e)
            return nil   // 录的时候不让按键传出去，也就不会有提示音
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        HotKeyMonitor.shared.paused = false
        held = []
    }

    private func finish(_ sc: Shortcut?) {
        let done = onDone
        onDone = nil
        stop()
        done?(sc)
    }

    private func handle(_ e: NSEvent) {
        let code = Int64(e.keyCode)
        switch e.type {
        case .flagsChanged:
            guard let nf = KeyNames.nsFlag(code) else { return }
            for c in KeyNames.cgFlags.keys { if let f = KeyNames.nsFlag(c), !e.modifierFlags.contains(f) { cur.remove(c) } }
            if e.modifierFlags.contains(nf) && !cur.contains(code) { cur.insert(code) } else { cur.remove(code) }
        case .keyDown:
            if e.isARepeat { return }
            if code == 53 && cur.isEmpty { return finish(nil) }   // 单按 Esc 取消
            cur.insert(code)
        case .keyUp:
            cur.remove(code)
        default:
            return
        }
        if cur.count >= peak.count { peak = cur }
        held = KeyNames.sorted(cur)

        guard cur.isEmpty, !peak.isEmpty else { return }
        // 所有键都松开了：把按得最多的那一刻当成用户想要的组合
        let chosen = peak
        peak = []
        if chosen.count > 3 { message = "Use at most 3 keys together."; return }
        let plain = chosen.filter { !KeyNames.isModifier($0) }
        if plain.count > 1 { message = "Use at most one regular key, plus modifier keys."; return }
        if let p = plain.first, plain.count == chosen.count, !KeyNames.standalone.contains(p) {
            message = "A regular key needs a partner. Hold Fn, Control, Option, Shift or Cmd together with it."
            return
        }
        finish(Shortcut(codes: Array(chosen)))
    }
}

// MARK: - 设置里的快捷键输入框

struct DictateShortcutEditor: View {
    @EnvironmentObject var app: AppState
    /// 编辑哪一组快捷键：听写的，或「问点什么」的
    var keyPath: WritableKeyPath<AppSettings, [Shortcut]> = \.dictateShortcuts
    @StateObject private var rec = ShortcutRecorder()
    /// 正在录第几个；等于 count 表示正在录一个新增的
    @State private var target: Int? = nil

    private var shortcuts: [Shortcut] { app.settings[keyPath: keyPath] }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(shortcuts.enumerated()), id: \.offset) { i, sc in
                HStack(spacing: 8) {
                    field(index: i, shortcut: sc)
                    if shortcuts.count > 1 && target != i {
                        Button(action: { app.settings[keyPath: keyPath].remove(at: i) }) {
                            Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(Theme.secondary)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if target == shortcuts.count {
                field(index: shortcuts.count, shortcut: nil)
            } else {
                Button(action: { begin(shortcuts.count) }) { Text("Add another").font(.system(size: 13)) }
                    .buttonStyle(OutlineButtonStyle())
            }
            if let m = rec.message {
                Text(m).font(.system(size: 12)).foregroundColor(Theme.danger).multilineTextAlignment(.trailing).frame(width: 230, alignment: .trailing)
            } else if target != nil {
                Text("Press the keys together, then let go. Esc cancels.").font(.system(size: 12)).foregroundColor(Theme.secondary)
                    .multilineTextAlignment(.trailing).frame(width: 230, alignment: .trailing)
            } else if shortcuts.contains(where: { $0.hasPlainKey }) && !app.perms.accessibility {
                Text("Allow Accessibility so the regular key isn't also typed into your app.").font(.system(size: 12))
                    .foregroundColor(Theme.secondary).multilineTextAlignment(.trailing).frame(width: 230, alignment: .trailing)
            }
        }
        .onDisappear { rec.stop(); target = nil }
    }

    private func field(index: Int, shortcut: Shortcut?) -> some View {
        let recording = target == index
        return Button(action: { begin(index) }) {
            HStack(spacing: 6) {
                if recording {
                    if rec.held.isEmpty {
                        Text("Press keys together…").font(.system(size: 13)).foregroundColor(Theme.secondary)
                    } else {
                        ForEach(rec.held, id: \.self) { KeyChip(text: KeyNames.name($0)) }
                    }
                } else if let shortcut {
                    ForEach(shortcut.labels, id: \.self) { KeyChip(text: $0) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(width: 214, height: 40)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(recording ? Theme.accent : Theme.stroke.opacity(2), lineWidth: recording ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    /// 听写和问点什么不能用同一个键：另一组里已经有就返回那一组的名字
    private func otherGroupHas(_ sc: Shortcut) -> String? {
        if keyPath == \.askShortcuts { return app.settings.dictateShortcuts.contains(sc) ? "Dictate" : nil }
        return app.settings.askShortcuts.contains(sc) ? "Ask anything" : nil
    }

    private func begin(_ index: Int) {
        target = index
        rec.start { sc in
            DispatchQueue.main.async {
                if let sc, let clash = otherGroupHas(sc) {
                    rec.message = "\(sc.labels.joined(separator: " + ")) is already used for \(clash). Pick a different key combination."
                } else if let sc, sc.isSingleModifier, sc.codes.count == 1, keyPath == \.askShortcuts, (sc.codes[0] == 54 || sc.codes[0] == 55) {
                    rec.message = "If you pressed ⌘ + Space, macOS Spotlight took the Space key. Change the Spotlight shortcut in System Settings → Keyboard → Keyboard Shortcuts → Spotlight, or pick another combination."
                } else if let sc {
                    if index < app.settings[keyPath: keyPath].count { app.settings[keyPath: keyPath][index] = sc }
                    else if !app.settings[keyPath: keyPath].contains(sc) { app.settings[keyPath: keyPath].append(sc) }
                }
                target = nil
            }
        }
    }
}
