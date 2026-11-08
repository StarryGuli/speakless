import SwiftUI
import AppKit

struct HistoryView: View {
    @EnvironmentObject var app: AppState
    @State private var filter = "All"
    @State private var confirmDeleteAll = false

    private var items: [HistoryItem] {
        app.history.filter { filter == "All" || $0.kind.rawValue == filter }
    }

    private var groups: [(String, [HistoryItem])] {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateStyle = .medium; f.locale = Locale(identifier: "en_US")
        var order: [String] = []
        var map: [String: [HistoryItem]] = [:]
        for it in items {
            let key = cal.isDateInToday(it.date) ? "Today" : (cal.isDateInYesterday(it.date) ? "Yesterday" : f.string(from: it.date))
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(it)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("History").font(.system(size: 34, weight: .semibold, design: .rounded))
                Spacer()
                Menu {
                    Button("Delete all", role: .destructive) { confirmDeleteAll = true }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34)
            }
            .padding(.top, 22)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Keep history", systemImage: "internaldrive").font(.system(size: 14, weight: .semibold))
                        Text("Choose how long to keep your history on this device.").font(.system(size: 13.5)).foregroundColor(Theme.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { app.settings.keepHistory }, set: { app.settings.keepHistory = $0 })) {
                        ForEach(KeepHistory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                }
                .padding(14)
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 3) {
                    Label("Your recordings stay on this Mac", systemImage: "lock").font(.system(size: 14, weight: .semibold))
                    Text("Audio and history are stored only on this device. Speech is sent to SiliconFlow once, to be recognised and corrected, and is not saved by this app anywhere else.")
                        .font(.system(size: 13.5)).foregroundColor(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))

            PillTabs(items: ["All", "Dictations", "Ask anything"], selection: $filter)

            if items.isEmpty {
                VStack(spacing: 8) {
                    Text("No dictations yet").font(.system(size: 20, weight: .semibold))
                    Text("Once you dictate across different apps, your\nentire dictation history will appear here.")
                        .multilineTextAlignment(.center).font(.system(size: 14)).foregroundColor(Theme.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 70)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.0) { g in
                            Text(g.0).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.secondary).padding(.top, 8)
                            ForEach(g.1) { HistoryRow(item: $0) }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(.horizontal, 26)
        .alert("Delete all history?", isPresented: $confirmDeleteAll) {
            Button("Delete all", role: .destructive) { app.deleteAllHistory() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This also removes the saved audio. It can't be undone.") }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var app: AppState
    let item: HistoryItem
    @State private var hover = false
    @State private var expanded = false
    @State private var copied = false

    private var time: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: item.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                Text(time).font(.system(size: 13)).foregroundColor(Theme.secondary).frame(width: 44, alignment: .leading)
                if item.text.isEmpty, FileManager.default.fileExists(atPath: app.audioURL(item.id).path) {
                    // 识别失败但录音还在：直接给一个看得见的 Retry，不用点开菜单
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundColor(Color(hex: 0xE59A2F))
                        Text(item.note ?? "Not recognized").font(.system(size: 14)).foregroundColor(Theme.secondary).lineLimit(2)
                        Spacer(minLength: 8)
                        Button("Retry") { DictationController.shared.retry(item) }.buttonStyle(OutlineButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(item.text).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                timing
                HStack(spacing: 4) {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13)).frame(width: 28, height: 28)
                    }.buttonStyle(.plain).help("Copy")
                    Menu {
                        Button("Show details") { expanded.toggle() }
                        if FileManager.default.fileExists(atPath: app.audioURL(item.id).path) {
                            Button("Retry") { DictationController.shared.retry(item) }
                        }
                        Divider()
                        Button("Delete transcript", role: .destructive) { app.deleteHistory(item) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
                }
                .foregroundColor(Theme.secondary)
                .opacity(hover || expanded ? 1 : 0)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    detail("Heard", item.raw)
                    detail("Recognition", "\(ModelCatalog.title(for: item.asrModel, in: ModelCatalog.asr)) · \(item.asrMs) ms")
                    if let sg = item.segmentsMs, sg.count > 1 { detail("Parts", sg.map { String(format: "%.1f", Double($0) / 1000) }.joined(separator: " / ") + " s") }
                    if let l = item.loadMs, l >= 3000 { detail("Model load", secs(l)) }
                    if let c = item.correctorModel {
                        detail("Correction", "\(ModelCatalog.title(for: c, in: ModelCatalog.correctors)) · \(item.correctionMs) ms")
                    }
                    if let n = item.note { detail("Note", n) }
                    if !item.appName.isEmpty { detail("App", item.appName) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.cardInner))
                .padding(.leading, 58)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(radius: 14)
        .onHover { hover = $0 }
    }

    private func secs(_ ms: Int) -> String { String(format: ms >= 10000 ? "%.0f s" : "%.1f s", Double(ms) / 1000) }
    private func shortModel(_ m: String) -> String { m.split(separator: "/").last.map(String.init) ?? m }

    /// 每一步一行：耗时 · 本地/在线 · 平台 · 模型。装载耗时跟在识别耗时后面，分段耗时放在展开的详情里
    private var timing: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if item.kind == .dictation, !item.asrModel.isEmpty {
                line("Recognise", recTime, local: item.asrLocal ?? item.asrProvider.flatMap { app.provider($0)?.isLocalModel }, provider: shortProv(item.asrProviderName ?? item.asrProvider.flatMap { app.provider($0)?.name } ?? item.asrProvider), model: item.asrModel)
                if let c = item.correctorModel {
                    line("Correct", secs(item.correctionMs), local: item.correctorLocal ?? item.correctorProvider.flatMap { app.provider($0)?.isLocalModel }, provider: shortProv(item.correctorProviderName ?? item.correctorProvider.flatMap { app.provider($0)?.name } ?? item.correctorProvider), model: c)
                }
            }
        }
        .font(.system(size: 10.5)).foregroundColor(Theme.secondary)
        .frame(width: 300, alignment: .trailing)
    }

    /// 平台名去掉括号和中文，只留短的英文名（SiliconFlow 硅基流动 (China) → SiliconFlow）
    private func shortProv(_ n: String?) -> String? {
        guard var t = n else { return nil }
        if let i = t.range(of: " (") { t = String(t[..<i.lowerBound]) }
        let short = t.unicodeScalars.filter { !(0x4E00...0x9FFF).contains($0.value) }.map(String.init).joined().trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? t : short
    }

    private var recTime: String {
        if let l = item.loadMs, l >= 3000 { return secs(item.asrMs) + " (load \(secs(l)))" }
        return secs(item.asrMs)
    }

    private func line(_ title: String, _ time: String, local: Bool?, provider: String?, model: String) -> some View {
        let tag = local.map { $0 ? "Local" : "Online" }
        let parts = [tag, provider, shortModel(model)].compactMap { $0 }.joined(separator: " · ")
        return (Text(title + " ") + Text(time).fontWeight(.semibold).foregroundColor(.primary) + Text(" · " + parts))
            .lineLimit(1).truncationMode(.middle)
    }

    private func detail(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.system(size: 12)).foregroundColor(Theme.secondary).frame(width: 78, alignment: .leading)
            Text(v).font(.system(size: 12.5)).textSelection(.enabled)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
