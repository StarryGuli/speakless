import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.window.ignoresSafeArea()
                HStack(spacing: 0) {
                    SidebarView().padding(8)
                    Group {
                        switch app.page {
                        case .home: HomeView()
                        case .history: HistoryView()
                        case .dictionary: DictionaryView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if app.showSettings {
                    SettingsOverlay().transition(.opacity)
                }
            }
            .environment(\.layout, LayoutInfo(width: geo.size.width, height: geo.size.height))
        }
        .frame(minWidth: 520, minHeight: 440)
        .background(WindowAccessor())
        .animation(.easeOut(duration: 0.15), value: app.showSettings)
        .foregroundColor(Theme.text)
    }
}

// MARK: - 侧边栏（窄的时候收成只剩图标）

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.layout) private var layout

    var body: some View {
        let compact = layout.compact
        VStack(alignment: compact ? .center : .leading, spacing: 0) {
            Spacer().frame(height: 40)   // 给左上角的红黄绿按钮留位置

            if compact {
                LogoMark().frame(width: 22, height: 20).padding(.bottom, 16)
            } else {
                HStack(spacing: 9) {
                    LogoMark().frame(width: 22, height: 20)
                    Text("Speakless").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("Local")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.navActive))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }

            VStack(spacing: 2) {
                ForEach(Page.allCases) { p in
                    Button(action: { app.page = p }) {
                        HStack(spacing: 10) {
                            Image(systemName: p.icon).font(.system(size: compact ? 16 : 14)).frame(width: 18)
                            if !compact {
                                Text(p.rawValue).font(.system(size: 14.5))
                                Spacer()
                            }
                        }
                        .foregroundColor(app.page == p ? Theme.text : Theme.secondary)
                        .padding(.horizontal, compact ? 0 : 12)
                        .frame(width: compact ? 46 : nil, height: compact ? 40 : 36)
                        .frame(maxWidth: compact ? 46 : .infinity)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(app.page == p ? Theme.navActive : Color.clear))
                        .hoverBorder(radius: 9, strength: 0.8)
                    }
                    .buttonStyle(.plain)
                    .help(p.rawValue)
                }
            }
            .padding(.horizontal, compact ? 0 : 10)

            Spacer()

            if compact {
                Button(action: { app.openSettings(.models) }) {
                    Image(systemName: "cpu").font(.system(size: 16)).foregroundColor(.white)
                        .frame(width: 46, height: 40)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.accent))
                }
                .buttonStyle(.plain).help("Switch models").padding(.bottom, 10)
            } else {
                ModelsCard().padding(.horizontal, 10).padding(.bottom, 10)
            }

            Group {
                if compact {
                    VStack(spacing: 0) {
                        footerButton("person.crop.circle", "Account") { app.openSettings(.account) }
                        footerButton("gearshape", "Settings") { app.openSettings(.settings) }
                        footerButton("questionmark.circle", "Help") { app.openSettings(.help) }
                    }
                } else {
                    HStack {
                        footerButton("person.crop.circle", "Account") { app.openSettings(.account) }
                        Spacer()
                        footerButton("gearshape", "Settings") { app.openSettings(.settings) }
                        footerButton("questionmark.circle", "Help") { app.openSettings(.help) }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .top)
        }
        .frame(width: compact ? 78 : 202)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.sidebar))
    }

    private func footerButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(Theme.secondary).frame(width: 32, height: 32)
        }.buttonStyle(.plain).help(help)
    }
}

/// 左下角的小卡片：当前用的识别模型和纠错模型，点一下去换
struct ModelsCard: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models in use").font(.system(size: 13)).foregroundColor(Theme.secondary)
            line("mic", platformShort(app.settings.asr.providerId) + ModelCatalog.title(for: app.settings.asrModel, in: ModelCatalog.asr))
            line("wand.and.stars", app.settings.correctionEnabled
                 ? platformShort(app.settings.correction.providerId) + ModelCatalog.title(for: app.settings.correctorModel, in: ModelCatalog.correctors) : "Correction off")
            Button("Switch models") { app.openSettings(.models) }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardInner))
    }

    /// 「平台 · 」前缀（只用名字的第一个词，侧栏地方小）
    private func platformShort(_ id: String) -> String {
        let n = app.provider(id)?.name ?? ""
        let first = n.split(separator: " ").first.map(String.init) ?? n
        return first.isEmpty ? "" : first + " · "
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(Theme.secondary).frame(width: 14)
            Text(text).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
        }
    }
}
