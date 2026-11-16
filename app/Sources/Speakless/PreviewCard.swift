import SwiftUI
import AppKit

/// 悬浮条上方的"处理预览"：识别结果一出来先把原文显示出来，整理要等一会儿时再标上"正在思考"，
/// 整理完后在原文上标出改了什么（删掉的划线、新增的绿色加粗），停一小会儿再收起。
/// 整理很快（不到 0.6 秒）时根本不弹出，免得闪一下。
final class PreviewState: ObservableObject {
    static let shared = PreviewState()
    @Published var raw = ""
    @Published var fixed: String? = nil
}

final class PreviewCard {
    static let shared = PreviewCard()
    private var panel: NSPanel?
    private var arm: DispatchWorkItem?
    private var gen = 0
    private var shownAt = Date.distantPast
    private let state = PreviewState.shared

    /// 识别完成、开始整理：0.6 秒后还没整理完才弹出
    func begin(raw: String) {
        onMain {
            self.gen += 1
            let g = self.gen
            self.arm?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.gen == g else { return }
                self.state.raw = raw
                self.state.fixed = nil
                self.shownAt = Date()
                self.show()
            }
            self.arm = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
    }

    /// 整理完成：弹出过就显示结果，并保证整张卡片至少停留 1.8 秒（改动了再多停一会儿），避免一闪而过
    func finish(fixed: String?) {
        onMain {
            self.arm?.cancel()
            guard self.panel?.isVisible == true else { return }
            self.gen += 1
            let g = self.gen
            let changed = fixed != nil && fixed != self.state.raw
            self.state.fixed = fixed ?? self.state.raw
            let minStay = max(0, 1.2 - Date().timeIntervalSince(self.shownAt))
            let stay = max(minStay, changed ? 2.0 : 0.6)
            DispatchQueue.main.asyncAfter(deadline: .now() + stay) { if self.gen == g { self.hide() } }
        }
    }

    func hide() {
        onMain {
            self.gen += 1
            self.arm?.cancel()
            self.panel?.orderOut(nil)
        }
    }

    private func show() {
        let p = panel ?? makePanel()
        if let f = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 22 + 36 + 10))
        }
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: PreviewCardView())
        panel = p
        return p
    }
}

struct PreviewCardView: View {
    @ObservedObject private var s = PreviewState.shared

    var body: some View {
        VStack { Spacer(minLength: 0); card }
            .frame(width: 560, height: 220, alignment: .bottom)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let fixed = s.fixed {
                let r = Self.diff(old: s.raw, new: fixed)
                HStack(spacing: 6) {
                    Image(systemName: r.count == 0 ? "checkmark.circle.fill" : "sparkle").font(.system(size: 11))
                    Text(r.count == 0 ? "No changes needed" : "Cleaned up · \(r.count) edit\(r.count == 1 ? "" : "s")")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundColor(Color(hex: 0x58D3A0))
                Text(r.text).font(.system(size: 15)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            } else {
                ShimmerText(text: "Thinking")
                Text(s.raw).font(.system(size: 15)).foregroundColor(.white.opacity(0.6)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        .animation(.easeOut(duration: 0.2), value: s.fixed)
        .frame(maxHeight: 200, alignment: .bottom)
    }

    /// 逐字对比：只显示整理后的文字，新增/改动的部分用绿色底色标出；返回改动处数（连续的算一处）
    static func diff(old: String, new: String) -> (text: AttributedString, count: Int) {
        let a = Array(old), b = Array(new)
        var inserted = Set<Int>(), removedAt = Set<Int>()   // removedAt：新文本里"这个位置之前"删掉过字
        let d = b.difference(from: a)
        var map = [Int: Int]()   // 旧下标 → 新下标（保留的字）
        var oi = 0, ni = 0
        let rem = Set(d.compactMap { c -> Int? in if case .remove(let o, _, _) = c { return o } else { return nil } })
        let ins = Set(d.compactMap { c -> Int? in if case .insert(let o, _, _) = c { return o } else { return nil } })
        while oi < a.count || ni < b.count {
            if oi < a.count, rem.contains(oi) { removedAt.insert(ni); oi += 1 }
            else if ni < b.count, ins.contains(ni) { inserted.insert(ni); ni += 1 }
            else { map[oi] = ni; oi += 1; ni += 1 }
        }
        var out = AttributedString()
        var runs = 0, prev = false
        for (j, ch) in b.enumerated() {
            var t = AttributedString(String(ch))
            let hit = inserted.contains(j)
            if hit {
                t.foregroundColor = Color(hex: 0x7BE3B5)
                t.backgroundColor = Color(hex: 0x58D3A0).opacity(0.2)
                if !prev { runs += 1 }
            } else {
                t.foregroundColor = Color.white.opacity(0.92)
                if removedAt.contains(j), !prev { runs += 1 }
            }
            prev = hit
            out += t
        }
        return (out, runs)
    }
}
