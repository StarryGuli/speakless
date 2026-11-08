import Foundation
import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import ApplicationServices
import CatchObjC

// MARK: - 权限

enum Permissions {
    static func current() -> PermissionState {
        PermissionState(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            inputMonitoring: CGPreflightListenEventAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    static func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in onMain { AppState.shared.refreshPermissions() } }
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        open("Privacy_ListenEvent")
    }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        open("Privacy_Accessibility")
    }

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - 麦克风设备

struct MicDevice: Identifiable, Hashable {
    let id: String   // uid
    let name: String
}

enum AudioDevices {
    static func inputs() -> [MicDevice] {
        AVCaptureDevice.devices(for: .audio).map { MicDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func defaultName() -> String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default"
    }

    /// 这个设备有没有输入声道（有的设备只能出声，不能录音）
    static func hasInput(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    static func name(of dev: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
        return st == noErr ? (cf as String?) : nil
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cfuid = uid as CFString
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafePointer(to: &cfuid) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
        }
        return (st == noErr && dev != 0) ? dev : nil
    }
}

// MARK: - 录音（16kHz 单声道）

/// 当前音量。录音线程只管往里写，悬浮条每一帧自己来读：
/// 音量不再经过 AppState，免得每秒几十次刷新整个界面。
final class LevelMeter {
    static let shared = LevelMeter()
    var level: Float = 0
    /// 只在做预览图时用：给波形一个固定的形状
    var preview: [Double]? = nil
}

/// 录音和麦克风相关的日志（最近 150 行），在 设置 → Audio 里能看。出问题时先看这里。
enum RecLog {
    static var url: URL { AppPaths.support.appendingPathComponent("recorder.log") }
    private static let lock = NSLock()

    static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        lines.append("\(f.string(from: Date()))  \(message)")
        if lines.count > 150 { lines.removeFirst(lines.count - 150) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    static func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

struct RecStats {
    var seconds = 0.0
    var peak: Float = 0
    var voicedSeconds = 0.0   // 音量够大、像是在说话的那部分有多长
    var device = ""
}

/// 录音。要点（都是被真实崩溃和"通话之后识别不出来"逼出来的）：
/// 1. 每次录音都新建一个 AVAudioEngine，不重用上一次的：通话结束、耳机切换、换麦克风之后，旧的引擎会留着过期的设置。
/// 2. 不再手动指定声音格式（format: nil），让系统给出麦克风当前真实的格式；以前格式对不上时 AVFoundation 会抛
///    Objective-C 异常，Swift 接不住，整个 App 直接崩掉。现在额外用 SLTryObjC 包住，出错变成普通错误。
/// 3. 录音过程中麦克风或格式变了（通话开始/结束、插拔耳机），自动重建引擎接着录，不会中断或崩溃。
/// 4. 多声道麦克风混成单声道时，只取有声音的声道，避免某个声道是静音时把声音抵消掉。
/// 5. 记录这一段里最大音量和"像在说话"的时长，用来发现麦克风被占用、只有噪声的情况。
final class Recorder {
    private let queue = DispatchQueue(label: "speakless.recorder", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converters: [Double: (conv: AVAudioConverter, fmt: AVAudioFormat)] = [:]
    private var samples: [Float] = []
    private let lock = NSLock()
    private var running = false
    private var wantedDevice: String?
    private var deviceName = ""
    private var skipRemaining = 0
    private var startedAt = Date()
    private var peakValue: Float = 0
    private var voicedSec = 0.0
    private var restartCount = 0

    var onLevel: ((Float) -> Void)?
    private var levelRef: Float = 0.35
    /// 开头这一小段不要（提示音播放的时候，别让它被录进去）
    var skipSeconds = 0.0
    /// 需要让界面知道的事（比如录音中麦克风丢了）
    var onLost: ((String) -> Void)?
    private(set) var lastStats = RecStats()
    /// 最近一次 stop() 取回的完整音频（边说边识别要从里面取最后那一小段）
    private(set) var lastPCM: [Float] = []

    /// 从第 start 个样本到现在录到的声音（边说边识别用，只拷贝这一段）
    func pcm(from start: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard start < samples.count else { return [] }
        return Array(samples[start...])
    }

    /// 这一段里目前为止最大的音量（0...1）
    func currentPeak() -> Float { lock.lock(); defer { lock.unlock() }; return peakValue }
    var currentDeviceName: String { lock.lock(); defer { lock.unlock() }; return deviceName }

    /// 异步启动；完成后在主线程回调（成功时 error 为 nil）
    func start(deviceUID: String?, completion: @escaping (Error?) -> Void) {
        let skip = skipSeconds
        queue.async {
            do {
                self.teardown()
                self.lock.lock()
                self.samples = []; self.skipRemaining = Int(skip * 16000)
                self.peakValue = 0; self.voicedSec = 0; self.startedAt = Date(); self.restartCount = 0
                self.lock.unlock()
                self.wantedDevice = deviceUID
                try self.buildAndStart(deviceUID: deviceUID)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                RecLog.write("start failed: \(error.localizedDescription)")
                self.teardown()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// 同一次录音里换一个全新的引擎接着录（已经录到的声音保留）
    func restart() {
        scheduleReopen(reason: "restart requested")
    }

    /// 同步停止并取回音频（如果启动还没完成，会等它完成）
    func stop() -> (wav: Data, seconds: Double) {
        queue.sync {
            teardown()
            lock.lock(); let pcm = samples; lastPCM = pcm; samples = []; let peak = peakValue; let voiced = voicedSec; lock.unlock()
            LevelMeter.shared.level = 0
            let secs = Double(pcm.count) / 16000
            lastStats = RecStats(seconds: secs, peak: peak, voicedSeconds: voiced, device: deviceName)
            RecLog.write(String(format: "stopped: %.1f s of audio, peak %.4f, speech-like %.2f s, device %@, engine restarts %d", secs, peak, voiced, deviceName, restartCount))
            return (Recorder.wav(from: pcm), secs)
        }
    }

    // MARK: 内部（都在 queue 上）

    private func teardown() {
        lock.lock(); reopenToken += 1; lock.unlock()
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let e = engine {
            _ = SLTryObjC({ e.inputNode.removeTap(onBus: 0) }, nil)
            e.stop()
        }
        engine = nil
        converters = [:]
        running = false
    }

    private func buildAndStart(deviceUID: String?) throws {
        // 指定的麦克风启动失败（格式对不上等）时，退回系统默认麦克风再试，而不是让这次听写直接失败
        if let uid = deviceUID {
            do { try buildAndStartOnce(deviceUID: uid); return }
            catch {
                RecLog.write("the chosen microphone failed to start (\(error.localizedDescription)) — falling back to the system default")
                teardown()
            }
        }
        try buildAndStartOnce(deviceUID: nil)
    }

    private func buildAndStartOnce(deviceUID: String?) throws {
        let eng = AVAudioEngine()
        var name = AudioDevices.defaultName()
        if let uid = deviceUID {
            guard let dev = AudioDevices.deviceID(forUID: uid), AudioDevices.hasInput(dev) else {
                throw APIError(message: "the chosen microphone isn't available right now")
            }
            try eng.inputNode.auAudioUnit.setDeviceID(dev)
            name = AudioDevices.name(of: dev) ?? uid
        }
        let input = eng.inputNode
        let hw = input.inputFormat(forBus: 0)   // 硬件那一侧的真实格式（换设备之后 outputFormat 可能还是旧的）
        RecLog.write("input: \(name), \(Int(hw.sampleRate)) Hz, \(hw.channelCount) channel(s)")
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw APIError(message: "The microphone isn't giving a usable audio format right now (\(name)). If a call or another app is using it, finish that first, or pick another microphone in Settings → Audio.")
        }
        var err: NSError?
        // 用换过设备之后的真实格式装 tap（不再沿用换设备之前的格式）
        let ok = SLTryObjC({
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buf, _ in self?.process(buf) }
        }, &err)
        guard ok else { throw APIError(message: "Can't read the microphone (\(name)): \(err?.localizedDescription ?? "unknown error")") }
        eng.prepare()
        do { try eng.start() } catch { _ = SLTryObjC({ input.removeTap(onBus: 0) }, nil); throw error }
        engine = eng
        running = true
        lock.lock(); deviceName = name; lock.unlock()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: eng, queue: nil) { [weak self] _ in
            self?.scheduleReopen(reason: "audio configuration changed (microphone, headset or call started or ended)")
        }
    }

    /// 系统连着发好几条“设备变了”的通知，而且它还在处理上一条的时候就重建引擎会互相等锁卡死。
    /// 所以等一小会儿、把多条合并成一次，再在自己的队列里重建。
    private var reopenToken = 0
    private func scheduleReopen(reason: String) {
        lock.lock(); reopenToken += 1; let token = reopenToken; lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.reopenToken; self.lock.unlock()
            guard token == current else { return }
            self.reopen(reason: reason)
        }
    }

    private func reopen(reason: String) {
        guard running || engine != nil else { return }
        restartCount += 1
        RecLog.write("restarting the audio engine: \(reason)")
        teardown()
        do {
            try buildAndStart(deviceUID: wantedDevice)
            running = true
        } catch {
            running = false
            RecLog.write("restart failed: \(error.localizedDescription)")
            DispatchQueue.main.async { self.onLost?(error.localizedDescription) }
        }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        guard n > 0, let ch = buf.floatChannelData else { return }
        let channels = Int(buf.format.channelCount)
        let rate = buf.format.sampleRate

        // 混成单声道：只取有声音的声道，免得某个声道是静音时把声音抵消掉
        var active: [Int] = []
        for c in 0..<channels {
            var e: Float = 0
            let p = ch[c]
            for i in 0..<n { e += p[i] * p[i] }
            if e > 1e-9 * Float(n) { active.append(c) }
        }
        let use = active.isEmpty ? Array(0..<channels) : active
        var mono = [Float](repeating: 0, count: n)
        for c in use { let p = ch[c]; for i in 0..<n { mono[i] += p[i] } }
        if use.count > 1 { let k = 1 / Float(use.count); for i in 0..<n { mono[i] *= k } }

        var sum: Float = 0, pk: Float = 0
        for v in mono { sum += v * v; pk = max(pk, abs(v)) }
        let rms = sqrt(sum / Float(n))
        lock.lock()
        peakValue = max(peakValue, pk)
        if rms > 0.006 { voicedSec += Double(n) / rate }
        lock.unlock()
        // 音量条：按分贝算（人耳对响度是对数的），再按最近的最响处自动放大，轻声说话、麦克风收音小的时候也动得明显
        let db = 20 * log10(max(rms, 1e-5))
        let raw = max(0, min(1, (db + 56) / 36))            // -56 dB → 0，-20 dB → 1
        levelRef = max(0.35, levelRef * 0.9985, raw)       // 约 6 秒内慢慢回落的参照
        onLevel?(min(1, raw / levelRef))

        // 变成 16kHz（输入采样率在录音中途变了也没关系：按每一块自己的采样率来）
        var out: [Float]
        if abs(rate - 16000) < 1 {
            out = mono
        } else {
            if converters[rate] == nil {
                guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                      let conv = AVAudioConverter(from: inFmt, to: outFormat) else { return }
                converters[rate] = (conv, inFmt)
            }
            guard let (conv, inFmt) = converters[rate],
                  let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(n)),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(n) * 16000 / rate) + 64) else { return }
            inBuf.frameLength = AVAudioFrameCount(n)
            mono.withUnsafeBufferPointer { src in inBuf.floatChannelData![0].update(from: src.baseAddress!, count: n) }
            var fed = false
            var cerr: NSError?
            conv.convert(to: outBuf, error: &cerr) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            guard cerr == nil, let o = outBuf.floatChannelData?[0] else { return }
            out = Array(UnsafeBufferPointer(start: o, count: Int(outBuf.frameLength)))
        }
        lock.lock()
        let drop = min(skipRemaining, out.count)
        skipRemaining -= drop
        if drop < out.count { samples.append(contentsOf: out[drop...]) }
        lock.unlock()
    }

    static func wav(from pcm: [Float], rate: Int = 16000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataBytes = UInt32(pcm.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        var body = Data(capacity: pcm.count * 2)
        for f in pcm {
            var s = Int16(max(-1, min(1, f)) * 32767).littleEndian
            body.append(Data(bytes: &s, count: 2))
        }
        d.append(body)
        return d
    }
}

// MARK: - 提示音 / 静音

enum SystemAudio {
    @discardableResult
    static func osa(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static func isMuted() -> Bool { osa("output muted of (get volume settings)") == "true" }
    static func setMuted(_ m: Bool) { osa("set volume output muted \(m ? "true" : "false")") }
}

// MARK: - 把文字写进光标处（剪贴板 + ⌘V，然后还原剪贴板）

enum InsertOutcome { case pasted, copiedNoPermission, copiedOnly }

enum Inserter {
    /// 文字一定会先放进剪贴板；`paste` 为 true 时再发一次 ⌘V。
    /// `restoreClipboard` 为 true 时，粘贴完成后把原来剪贴板里的东西放回去。
    @discardableResult
    static func insert(_ text: String, restoreClipboard: Bool, paste: Bool) -> InsertOutcome {
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = restoreClipboard ? (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        } : []
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard paste else { return .copiedOnly }
        guard AXIsProcessTrusted() else { return .copiedNoPermission }

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if restoreClipboard, !saved.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pb.clearContents()
                for item in saved {
                    let n = NSPasteboardItem()
                    for (t, d) in item { n.setData(d, forType: t) }
                    pb.writeObjects([n])
                }
            }
        }
        return .pasted
    }
}
