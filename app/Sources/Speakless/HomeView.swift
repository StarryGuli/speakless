import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.layout) private var layout

    var body: some View {
        // 内容区够宽才把「快捷键 / 权限」放在右边，不然挪到下面
        let stacked = layout.contentWidth < 700
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Speak, don't type")
                    .font(.system(size: layout.tiny ? 32 : 46, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.top, 22)

                if stacked {
                    VStack(alignment: .leading, spacing: 14) {
                        leftColumn
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 14) { ShortcutsCard(); PermissionsCard() }
                            VStack(spacing: 14) { ShortcutsCard(); PermissionsCard() }
                        }
                    }
                    .padding(.bottom, 28)
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        leftColumn.frame(maxWidth: .infinity)
                        VStack(spacing: 14) {
                            ShortcutsCard()
                            PermissionsCard()
                        }
                        .frame(width: 214)
                    }
                    .padding(.bottom, 28)
                }
            }
            .padding(.horizontal, layout.compact ? 16 : 26)
        }
    }

    @ViewBuilder private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !app.hasKey { KeyBanner() }
            HStack {
                Text("Insights").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundColor(Theme.secondary)
                Spacer()
                Button(action: share) {
                    Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 13))
                }.buttonStyle(OutlineButtonStyle())
            }
            let columns = layout.contentWidth < 360 ? 1 : 2
            let cols = Array(repeating: GridItem(.flexible(), spacing: 14), count: columns)
            LazyVGrid(columns: cols, spacing: 14) {
                StatCard(value: compact(app.totalWords), unit: "words", label: "Words dictated")
                StatCard(value: hours(app.minutesSaved).0, unit: hours(app.minutesSaved).1, label: "Time saved")
                StatCard(value: "\(app.averageWPM)", unit: "WPM", label: "Average dictation speed")
                StatCard(value: hours(Int(app.totalSeconds / 60)).0, unit: hours(Int(app.totalSeconds / 60)).1, label: "Total dictation time")
            }
            ActivityCard()
            UsageCard()
        }
    }

    private func share() {
        let s = "I've dictated \(compact(app.totalWords)) words with Speakless, saving about \(app.minutesSaved) minutes."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K") : "\(n)"
    }

    /// 返回 (数字, 单位) —— 超过 60 分钟时拆成 "17 hr 28 min" 这种
    private func hours(_ minutes: Int) -> (String, String) {
        minutes >= 60 ? ("\(minutes / 60)", "hr \(minutes % 60) min") : ("\(minutes)", "min")
    }
}

struct StatCard: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(unit).font(.system(size: 14, weight: .medium)).foregroundColor(Theme.text.opacity(0.85))
            }
            Text(label).font(.system(size: 14)).foregroundColor(Theme.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .cardStyle()
    }
}

struct ActivityCard: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let streaks = app.streaks
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    metric("\(app.activeDays)", "days", "Active days")
                    metric("\(streaks.current)", "days", "Current streak")
                    metric("\(streaks.longest)", "days", "Longest streak")
                }
                VStack(alignment: .leading, spacing: 8) {
                    metric("\(app.activeDays)", "days", "Active days")
                    metric("\(streaks.current)", "days", "Current streak")
                    metric("\(streaks.longest)", "days", "Longest streak")
                }
            }
            HeatmapContainer()
            HStack(spacing: 5) {
                Spacer()
                Text("Less").font(.system(size: 12)).foregroundColor(Theme.secondary)
                ForEach([0.0, 0.35, 0.55, 0.8, 1.0], id: \.self) { l in
                    RoundedRectangle(cornerRadius: 3).fill(Heatmap.color(level: l)).frame(width: 13, height: 13)
                }
                Text("More").font(.system(size: 12)).foregroundColor(Theme.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func metric(_ v: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(v).font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(unit).font(.system(size: 14, weight: .medium))
            }
            Text(label).font(.system(size: 14)).foregroundColor(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 热力图的列数跟着可用宽度走，窗口窄了就少画几周
struct HeatmapContainer: View {
    var body: some View {
        GeometryReader { g in
            Heatmap(weeks: max(8, min(30, Int((g.size.width - 22) / 20.5))))
        }
        .frame(height: 7 * 20.5 + 26)
    }
}

struct Heatmap: View {
    @EnvironmentObject var app: AppState
    let weeks: Int
    let cell: CGFloat = 15
    let gap: CGFloat = 5.5

    static func color(level: Double) -> Color {
        level <= 0 ? Theme.heat0 : Theme.accent.opacity(0.25 + 0.75 * level)
    }

    private func level(for words: Int) -> Double {
        switch words {
        case 0: return 0
        case 1..<60: return 0.35
        case 60..<250: return 0.55
        case 250..<800: return 0.8
        default: return 1
        }
    }

    var body: some View {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let starts: [Date] = (0..<weeks).map { cal.date(byAdding: .day, value: -7 * (weeks - 1 - $0), to: thisWeek) ?? thisWeek }
        let letters = ["S", "M", "T", "W", "T", "F", "S"]
        let monthFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM"; f.locale = Locale(identifier: "en_US"); return f }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(r % 2 == 0 ? letters[r] : "").font(.system(size: 10)).foregroundColor(Theme.secondary)
                            .frame(width: 10, height: cell)
                    }
                }
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { d in
                            let date = cal.date(byAdding: .day, value: d, to: starts[w]) ?? starts[w]
                            let words = app.daily[AppState.dayKey(date)]?.words ?? 0
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(date > today ? Color.clear : Heatmap.color(level: level(for: words)))
                                .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .stroke(date > today ? Theme.stroke : Color.clear, lineWidth: 1))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: 10 + gap)
                ForEach(0..<weeks, id: \.self) { w in
                    let m = cal.component(.month, from: starts[w])
                    let prev = w > 0 ? cal.component(.month, from: starts[w - 1]) : -1
                    Text(m != prev ? monthFmt.string(from: starts[w]) : "")
                        .font(.system(size: 11)).foregroundColor(Theme.secondary)
                        .fixedSize()
                        .frame(width: cell + gap, alignment: .leading)
                }
            }
        }
    }
}

struct ShortcutsCard: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dictateBlock
            block("Translate", ["Fn", "Right Cmd"], soon: true)
            askBlock
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var dictateBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dictate").font(.system(size: 13)).foregroundColor(Theme.secondary)
            ForEach(Array(app.settings.dictateShortcuts.enumerated()), id: \.offset) { _, sc in
                HStack(spacing: 6) { ForEach(sc.labels, id: \.self) { KeyChip(text: $0) } }
            }
        }
    }

    private var askBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask anything").font(.system(size: 13)).foregroundColor(Theme.secondary)
            ForEach(Array(app.settings.askShortcuts.enumerated()), id: \.offset) { _, sc in
                HStack(spacing: 6) { ForEach(sc.labels, id: \.self) { KeyChip(text: $0) } }
            }
        }
    }

    private func block(_ title: String, _ keys: [String], soon: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13)).foregroundColor(Theme.secondary)
                if soon {
                    Text("Soon").font(.system(size: 10, weight: .medium)).foregroundColor(Theme.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.navActive))
                }
            }
            HStack(spacing: 6) { ForEach(keys, id: \.self) { KeyChip(text: $0) } }.opacity(soon ? 0.55 : 1)
        }
    }
}

struct PermissionsCard: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup").font(.system(size: 13)).foregroundColor(Theme.secondary)
            row("Microphone", app.perms.microphone, Permissions.requestMicrophone)
            row("Input Monitoring", app.perms.inputMonitoring, Permissions.requestInputMonitoring)
            row("Accessibility", app.perms.accessibility, Permissions.requestAccessibility)
            if app.perms.inputMonitoring && !app.hotkeyActive {
                Text("Hotkey starting…").font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func row(_ title: String, _ ok: Bool, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Theme.green : Theme.danger).frame(width: 8, height: 8)
            Text(title).font(.system(size: 13))
            Spacer()
            if !ok {
                Button("Allow", action: action).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.accent)
            }
        }
    }
}

struct KeyBanner: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add your SiliconFlow API key").font(.system(size: 14, weight: .semibold))
                Text("Speakless needs it to recognise and correct your speech.").font(.system(size: 12.5)).foregroundColor(Theme.secondary)
            }
            Spacer()
            Button("Add key") { app.openSettings(.models) }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent.opacity(0.4)))
    }
}


/// 硅基流动用量：今天 / 本月 / 全部，按模型分别花了多少（人民币，按定价页估算）
struct UsageCard: View {
    @ObservedObject private var live = Live.shared
    @State private var period = "This month"

    private struct Row: Identifiable {
        var id: String; var calls = 0; var tokens = 0; var cny = 0.0; var priced = true
    }

    private var summary: (rows: [Row], cny: Double, calls: Int, tokens: Int, cacheRate: Double?) {
        _ = live.usageTick
        let now = Date(), cal = Calendar.current
        let fx = Pricing.cnyPerUsd
        let all = UsageLog.shared.all().filter { r in
            switch period {
            case "Today": return cal.isDate(r.ts, inSameDayAs: now)
            case "This month": return cal.isDate(r.ts, equalTo: now, toGranularity: .month)
            default: return true
            }
        }
        var map: [String: Row] = [:]
        let chatCalls = all.filter { $0.inputTokens > 0 }
        let inTok = chatCalls.reduce(0) { $0 + $1.inputTokens }, hitTok = chatCalls.reduce(0) { $0 + ($1.cachedTokens ?? 0) }
        let cacheRate: Double? = inTok > 0 ? Double(hitTok) / Double(inTok) : nil
        for r in all {
            let name = UsageReporter.shortName(r.model)
            var row = map[name] ?? Row(id: name)
            row.calls += 1
            row.tokens += r.inputTokens + r.outputTokens + (r.audioSeconds > 0 && r.inputTokens + r.outputTokens == 0 ? Int(r.audioSeconds * Pricing.audioTokensPerSecond) : 0)
            row.cny += r.costUsd * fx
            if !r.priced { row.priced = false }
            map[name] = row
        }
        let rows = map.values.sorted { $0.cny != $1.cny ? $0.cny > $1.cny : $0.calls > $1.calls }
        return (rows, rows.reduce(0) { $0 + $1.cny }, rows.reduce(0) { $0 + $1.calls }, rows.reduce(0) { $0 + $1.tokens }, cacheRate)
    }

    private func money(_ v: Double) -> String {
        v < 0.01 && v > 0 ? String(format: "¥%.4f", v) : String(format: "¥%.2f", v)
    }

    var body: some View {
        let s = summary
        let top = max(s.rows.map { $0.cny }.max() ?? 0, 0.000001)
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Usage").font(.system(size: 17, weight: .semibold, design: .rounded))
                    Spacer()
                    PillTabs(items: ["Today", "This month", "All time"], selection: $period)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage").font(.system(size: 17, weight: .semibold, design: .rounded))
                    PillTabs(items: ["Today", "This month", "All time"], selection: $period)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(money(s.cny)).font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("\(s.calls) call\(s.calls == 1 ? "" : "s") · \(s.tokens) tokens" + (s.cacheRate.map { String(format: " · prompt cache hit %.0f%%", $0 * 100) } ?? "")).font(.system(size: 13)).foregroundColor(Theme.secondary)
            }
            if s.rows.isEmpty {
                Text("No calls yet in this period. Dictate once and it shows up here.").font(.system(size: 13)).foregroundColor(Theme.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(s.rows) { r in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.id).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                                GeometryReader { g in
                                    Capsule().fill(Theme.accent.opacity(0.55))
                                        .frame(width: max(3, g.size.width * CGFloat(r.cny / top)), height: 4)
                                }.frame(height: 4)
                            }
                            Spacer(minLength: 8)
                            Text("\(r.calls) call\(r.calls == 1 ? "" : "s")").font(.system(size: 12)).foregroundColor(Theme.secondary).frame(width: 64, alignment: .trailing)
                            Text(r.priced ? money(r.cny) : "no price").font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(r.priced ? Theme.text : Theme.secondary).frame(width: 74, alignment: .trailing)
                        }
                    }
                }
            }
            Text("Estimated from SiliconFlow's price list, not your bill. Free models show ¥0; models without a known price show “no price”.")
                .font(.system(size: 11.5)).foregroundColor(Theme.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
