import Foundation

/// 边说边识别：录音期间每遇到一次够长的停顿，就把停顿之前这一段先送去识别，按下结束时只剩最后一小段要等。
/// 只对本机/自建（不要 key）的识别模型打开：这类模型耗时跟音频长度成正比（实测约 0.55–0.65 秒/秒录音），云端模型本来就很快，
/// 切段只会损失一点上下文，不值得。
/// 整理（纠错）仍然是把所有段拼成一整段文字之后一次做，不分段。
/// 任何一段识别失败，就退回「整段录音一次识别」，所以最坏情况和以前一样。
final class StreamASR {
    private let recorder: Recorder
    private let setup: Setup
    private let glossary: [String]
    private let pause: Double
    private let startAfter: Double       // 整段录音超过这么多秒才开始切，更短的全部整段识别
    private let minSegment = 3.0       // 一段至少这么长才切（太短的片段识别不准）
    private let maxSegment = 45.0      // 一直不停顿时，到这个长度就在最安静的地方硬切
    private let frame = 1600           // 0.1 秒一格
    private var peakRMS: Float = 0       // 这次录音里出现过的最大音量（声音小的麦克风也要能认出「在说话」）
    private var voicedRMS: Float { max(0.0025, min(0.008, peakRMS * 0.12)) }
    private(set) var committed = 0     // 已经切走（送出识别）的样本数
    private(set) var tasks: [Task<(text: String, ms: Int), Error>] = []
    private var timer: Timer?

    init(recorder: Recorder, setup: Setup, glossary: [String], pause: Double, startAfter: Double) {
        self.recorder = recorder; self.setup = setup; self.glossary = glossary; self.pause = max(1, pause); self.startAfter = startAfter
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    /// 停止计时，把「切走的各段结果」和「剩下的尾巴从哪开始」交给 process
    func finish() -> (tasks: [Task<(text: String, ms: Int), Error>], tailStart: Int) {
        timer?.invalidate(); timer = nil
        return (tasks, committed)
    }

    private func rmsFrames(_ pcm: [Float]) -> [Float] {
        stride(from: 0, to: pcm.count - frame + 1, by: frame).map { s in
            var sum: Float = 0
            for i in s..<(s + frame) { sum += pcm[i] * pcm[i] }
            return (sum / Float(frame)).squareRoot()
        }
    }

    private func tick() {
        let seg = recorder.pcm(from: committed)
        let secs = Double(seg.count) / 16000
        guard secs >= minSegment, Double(committed + seg.count) / 16000 >= startAfter else { return }
        let rms = rmsFrames(seg)
        peakRMS = max(peakRMS, rms.max() ?? 0)
        guard let lastVoiced = rms.lastIndex(where: { $0 > voicedRMS }) else {
            // 一直没人说话：丢掉这段静音，别让它越攒越长
            if secs > 10, (rms.max() ?? 0) < 0.002 { committed += seg.count - 16000 }
            return
        }
        let trailingSilence = Double(rms.count - 1 - lastVoiced) * 0.1
        var cut: Int? = nil
        if trailingSilence >= pause {
            cut = min(seg.count, (lastVoiced + 1) * frame + 4800)   // 留 0.3 秒收尾
        } else if secs >= maxSegment {
            // 硬切：在最后 15 秒里找最安静的那一格
            let from = max(0, rms.count - 150)
            if let q = (from..<rms.count).min(by: { rms[$0] < rms[$1] }) { cut = (q + 1) * frame }
        }
        guard let c = cut, c > 16000 else { return }
        let piece = Array(seg[0..<c])
        committed += c
        let setup = self.setup, glossary = self.glossary
        tasks.append(Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let text = try await ModelClient.shared.transcribe(wav: Recorder.wav(from: piece), setup: setup, glossary: glossary)
            return (text, Int(Date().timeIntervalSince(t0) * 1000))
        })
    }

    /// 把各段文字接起来：中文和中文之间不加空格，英文单词和数字之间加一个
    static func join(_ parts: [String]) -> String {
        var out = ""
        for p in parts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !p.isEmpty {
            if let a = out.unicodeScalars.last, let b = p.unicodeScalars.first, a.isASCII, b.isASCII,
               CharacterSet.alphanumerics.contains(a), CharacterSet.alphanumerics.contains(b) { out += " " }
            out += p
        }
        return out
    }

    /// 这段声音里有没有人在说话（尾巴只有静音时不送去识别，免得模型对着噪声编字）
    static func hasSpeech(_ pcm: [Float]) -> Bool {
        let f = 1600
        var frames: [Float] = []
        var s = 0
        while s + f <= pcm.count {
            var sum: Float = 0
            for i in s..<(s + f) { sum += pcm[i] * pcm[i] }
            frames.append((sum / Float(f)).squareRoot())
            s += f
        }
        return frames.filter { $0 > 0.0025 }.count >= 2
    }
}
