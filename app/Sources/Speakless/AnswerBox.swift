import SwiftUI
import AppKit

/// 回答框里显示的内容
final class AnswerState: ObservableObject {
    static let shared = AnswerState()
    enum Phase { case working(String), done, failed(String) }
    @Published var phase: Phase = .working("Thinking")
    @Published var question = ""
    @Published var text = ""
    @Published var sources: [SearchHit] = []
    @Published var query: String? = nil
    @Published var visible = false
    var onSize: (() -> Void)?
}

/// 「问点什么」的回答框：一块浮在屏幕下方、不抢焦点的小面板。回答显示在这里，不会往你正在写的地方粘贴；
/// 想用的话点 Insert，或者 Copy。
final class AnswerPanelController {
    static let shared = AnswerPanelController()
    private var panel: NSPanel?
    private var host: NSHostingView<AnswerView>?
    private let state = AnswerState.shared

    func show(question: String) {
        onMain {
            self.state.question = question
            self.state.text = ""; self.state.sources = []; self.state.query = nil
            self.state.phase = .working("Thinking")
            self.state.visible = true
            self.present()
        }
    }

    func status(_ s: String) { onMain { self.state.phase = .working(s); self.resize() } }

    func finish(text: String, sources: [SearchHit], query: String?) {
        onMain {
            self.state.text = text; self.state.sources = sources; self.state.query = query
            self.state.phase = .done
            self.resize()
        }
    }

    func fail(_ message: String) { onMain { self.state.phase = .failed(message); self.resize() } }

    func close() {
        onMain {
            self.state.visible = false
            self.panel?.orderOut(nil)
        }
    }

    private func present() {
        let p = panel ?? makePanel()
        resize()
        p.alphaValue = 1
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 160), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let h = NSHostingView(rootView: AnswerView())
        p.contentView = h
        host = h; panel = p
        return p
    }

    /// 内容变了就按内容高度重新定位：底边固定在悬浮条上方
    func resize() {
        guard let p = panel, let h = host, let screen = NSScreen.main else { return }
        h.layoutSubtreeIfNeeded()
        let size = h.fittingSize
        let f = screen.visibleFrame
        let w: CGFloat = 540
        let height = min(max(size.height, 90), f.height - 140)
        p.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 86, width: w, height: height), display: true)
    }
}

struct AnswerView: View {
    @ObservedObject private var s = AnswerState.shared
    @State private var copied = false

    private func md(_ t: String) -> AttributedString {
        (try? AttributedString(markdown: t, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 12)).foregroundColor(Color(hex: 0x58D3A0)).padding(.top, 2)
                Text(s.question).font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.65)).lineLimit(3)
                Spacer(minLength: 8)
                Button(action: { AnswerPanelController.shared.close() }) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.6)).frame(width: 22, height: 22)
                }.buttonStyle(.plain)
            }
            switch s.phase {
            case .working(let m):
                ShimmerText(text: m).frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
            case .failed(let m):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(Color(hex: 0xFFB84D))
                    Text(m).font(.system(size: 13.5)).foregroundColor(.white.opacity(0.9))
                }
            case .done:
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(md(s.text)).font(.system(size: 14.5)).foregroundColor(.white).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        if !s.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.query.map { "Searched: \($0)" } ?? "Sources").font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                                ForEach(Array(s.sources.enumerated()), id: \.element.id) { i, h in
                                    if let u = URL(string: h.url) {
                                        Link(destination: u) {
                                            Text("[\(i + 1)] \(h.title)").font(.system(size: 12)).foregroundColor(Color(hex: 0x7FB6FF)).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 330)
                HStack(spacing: 8) {
                    pillButton(copied ? "Copied" : "Copy", icon: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.text, forType: .string)
                        copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    pillButton("Insert at cursor", icon: "arrow.down.doc") {
                        let text = s.text
                        AnswerPanelController.shared.close()
                        Inserter.insert(text, restoreClipboard: false, paste: true)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 540, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(white: 0.24), lineWidth: 1))
        .padding(8)
    }

    private func pillButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundColor(.white).padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(Color(white: 0.22)))
        }.buttonStyle(.plain)
    }
}
