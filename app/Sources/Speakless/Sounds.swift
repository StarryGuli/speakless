import AppKit
import Foundation

enum SoundStyle: String, Codable, CaseIterable {
    case soft = "Soft", velvet = "Velvet", glass = "Glass", pop = "Pop", click = "Click", system = "System"
}

enum SoundKind: String { case start, stop, done, error }

/// 提示音：自己合成，不用系统自带的 Tink / Pop，也不带任何别人的音频素材。
enum Sounds {
    /// 开始提示音占用的时间；录音要跳过这一段，免得扬声器声音被麦克风录进去
    static func lead(_ style: SoundStyle) -> Double {
        switch style {
        case .soft: return 0.32
        case .velvet: return 0.34
        case .glass: return 0.3
        case .pop: return 0.16
        case .click: return 0.1
        case .system: return 0.25
        }
    }

    private static var cache: [String: NSSound] = [:]

    /// 启动时在后台把当前风格的四个声音合成好，第一次按键时不用现算
    static func warmUp() {
        let style = AppState.shared.settings.soundStyle
        guard style != .system else { return }
        DispatchQueue.global(qos: .utility).async {
            for kind in [SoundKind.start, .stop, .done, .error] {
                let data = Synth.wav(style: style, kind: kind)
                DispatchQueue.main.async {
                    if let s = NSSound(data: data) { cache["\(style.rawValue).\(kind.rawValue)"] = s }
                }
            }
        }
    }

    /// 按「设置里有没有开提示音」来播
    static func cue(_ kind: SoundKind) {
        guard AppState.shared.settings.interactionSounds else { return }
        play(kind, style: AppState.shared.settings.soundStyle)
    }

    static func play(_ kind: SoundKind, style: SoundStyle) {
        onMain {
            if style == .system {
                let name: String
                switch kind { case .start: name = "Tink"; case .stop: name = "Pop"; case .done: name = "Glass"; case .error: name = "Basso" }
                NSSound(named: name)?.play()
                return
            }
            let key = "\(style.rawValue).\(kind.rawValue)"
            let sound: NSSound
            if let c = cache[key] {
                sound = c
            } else {
                guard let s = NSSound(data: Synth.wav(style: style, kind: kind)) else { return }
                cache[key] = s
                sound = s
            }
            sound.stop()
            sound.volume = 0.8
            sound.play()
        }
    }

    /// 设置里「试听」：开始 → 结束 → 完成
    static func preview(_ style: SoundStyle) {
        play(.start, style: style)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { play(.stop, style: style) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { play(.done, style: style) }
    }
}

enum Synth {
    struct Note {
        var freq: Double
        var start: Double
        var dur: Double
        var gain: Double = 1
        var glideTo: Double? = nil
        var partials: [(ratio: Double, gain: Double)] = [(1, 1)]
        var noise = false
        var attack = 0.006      // 起音时间（秒）：越长越柔
        var decayDiv = 4.2      // 衰减快慢：越小，尾巴越长越松
    }

    private static let rate = 44100.0

    static func wav(style: SoundStyle, kind: SoundKind) -> Data {
        let notes = score(style, kind)
        let total = (notes.map { $0.start + $0.dur }.max() ?? 0.2) + 0.03
        var buf = [Float](repeating: 0, count: Int(total * rate))
        var seed: UInt32 = 12345

        for n in notes {
            let first = Int(n.start * rate)
            let count = Int(n.dur * rate)
            let tau = n.dur / (n.noise ? 5 : n.decayDiv)
            var phase = 0.0
            for i in 0..<count where first + i < buf.count {
                let t = Double(i) / rate
                let attack = min(1, t / (n.noise ? 0.0005 : n.attack))
                let release = min(1, (n.dur - t) / 0.012)
                let env = attack * release * exp(-t / tau)
                var s = 0.0
                if n.noise {
                    seed = seed &* 1664525 &+ 1013904223
                    let r = Double(Int32(bitPattern: seed)) / Double(Int32.max)
                    s = r * 0.8
                } else {
                    var f = n.freq
                    if let g = n.glideTo {
                        let x = min(1, t / n.dur)
                        f = n.freq + (g - n.freq) * (x * x * (3 - 2 * x))
                    }
                    phase += 2 * Double.pi * f / rate
                    for p in n.partials { s += sin(phase * p.ratio) * p.gain }
                }
                buf[first + i] += Float(s * env * n.gain)
            }
        }
        // 归一化到 0.55 的峰值：不削波、不刺耳
        let peak = max(0.0001, buf.map { abs($0) }.max() ?? 0.0001)
        let target: Double = style == .velvet ? 0.36 : (style == .soft ? 0.44 : 0.55)
        let k = Float(target) / peak
        return Recorder.wav(from: buf.map { $0 * k }, rate: Int(rate))
    }

    private static let soft: [(ratio: Double, gain: Double)] = [(1, 1), (2, 0.14), (3, 0.04)]
    private static let warm: [(ratio: Double, gain: Double)] = [(0.5, 0.10), (1, 1), (2, 0.05)]
    private static let velvet: [(ratio: Double, gain: Double)] = [(0.5, 0.14), (1, 1)]
    private static let bell: [(ratio: Double, gain: Double)] = [(1, 1), (2.76, 0.42), (5.4, 0.18), (8.93, 0.07)]

    private static func score(_ style: SoundStyle, _ kind: SoundKind) -> [Note] {
        switch style {
        case .soft, .system:
            // 比第一版低约四个半音，起音更慢，去掉高次谐波、加了一点低八度的暖感，尾巴更长
            switch kind {
            case .start: return [Note(freq: 440, start: 0, dur: 0.22, partials: warm, attack: 0.02, decayDiv: 3.3), Note(freq: 659.25, start: 0.09, dur: 0.27, gain: 0.85, partials: warm, attack: 0.02, decayDiv: 3.3)]
            case .stop: return [Note(freq: 659.25, start: 0, dur: 0.2, gain: 0.85, partials: warm, attack: 0.02, decayDiv: 3.3), Note(freq: 440, start: 0.085, dur: 0.27, partials: warm, attack: 0.02, decayDiv: 3.3)]
            case .done: return [Note(freq: 523.25, start: 0, dur: 0.26, gain: 0.85, partials: warm, attack: 0.02, decayDiv: 3.2), Note(freq: 783.99, start: 0.075, dur: 0.36, gain: 0.7, partials: warm, attack: 0.02, decayDiv: 3.2)]
            case .error: return [Note(freq: 196, start: 0, dur: 0.2, partials: warm, attack: 0.02, decayDiv: 3.3), Note(freq: 164.81, start: 0.1, dur: 0.28, partials: warm, attack: 0.02, decayDiv: 3.3)]
            }
        case .velvet:
            // 比 Soft 再低约三个半音，几乎是纯正弦，起音最慢
            switch kind {
            case .start: return [Note(freq: 349.23, start: 0, dur: 0.24, partials: velvet, attack: 0.03, decayDiv: 3.0), Note(freq: 523.25, start: 0.1, dur: 0.3, gain: 0.85, partials: velvet, attack: 0.03, decayDiv: 3.0)]
            case .stop: return [Note(freq: 523.25, start: 0, dur: 0.22, gain: 0.85, partials: velvet, attack: 0.03, decayDiv: 3.0), Note(freq: 349.23, start: 0.095, dur: 0.3, partials: velvet, attack: 0.03, decayDiv: 3.0)]
            case .done: return [Note(freq: 440, start: 0, dur: 0.28, gain: 0.85, partials: velvet, attack: 0.03, decayDiv: 3.0), Note(freq: 587.33, start: 0.08, dur: 0.4, gain: 0.7, partials: velvet, attack: 0.03, decayDiv: 3.0)]
            case .error: return [Note(freq: 174.61, start: 0, dur: 0.22, partials: velvet, attack: 0.03, decayDiv: 3.0), Note(freq: 146.83, start: 0.11, dur: 0.3, partials: velvet, attack: 0.03, decayDiv: 3.0)]
            }
        case .glass:
            switch kind {
            case .start: return [Note(freq: 1318.5, start: 0, dur: 0.42, partials: bell)]
            case .stop: return [Note(freq: 987.77, start: 0, dur: 0.38, partials: bell)]
            case .done: return [Note(freq: 1568, start: 0, dur: 0.3, gain: 0.8, partials: bell), Note(freq: 2093, start: 0.06, dur: 0.42, gain: 0.7, partials: bell)]
            case .error: return [Note(freq: 330, start: 0, dur: 0.4, partials: bell)]
            }
        case .pop:
            switch kind {
            case .start: return [Note(freq: 380, start: 0, dur: 0.1, glideTo: 780, partials: [(1, 1), (2, 0.1)])]
            case .stop: return [Note(freq: 780, start: 0, dur: 0.1, glideTo: 380, partials: [(1, 1), (2, 0.1)])]
            case .done: return [Note(freq: 520, start: 0, dur: 0.13, glideTo: 1040, partials: [(1, 1), (2, 0.1)])]
            case .error: return [Note(freq: 300, start: 0, dur: 0.16, glideTo: 170, partials: [(1, 1), (2, 0.25)])]
            }
        case .click:
            let tick = Note(freq: 0, start: 0, dur: 0.03, gain: 0.6, noise: true)
            switch kind {
            case .start: return [tick, Note(freq: 1900, start: 0, dur: 0.035, gain: 0.5)]
            case .stop: return [tick, Note(freq: 1200, start: 0, dur: 0.035, gain: 0.5)]
            case .done: return [tick, Note(freq: 1900, start: 0, dur: 0.035, gain: 0.5), Note(freq: 0, start: 0.07, dur: 0.03, gain: 0.5, noise: true), Note(freq: 2400, start: 0.07, dur: 0.035, gain: 0.45)]
            case .error: return [Note(freq: 150, start: 0, dur: 0.12, partials: [(1, 1), (2, 0.4)])]
            }
        }
    }
}
