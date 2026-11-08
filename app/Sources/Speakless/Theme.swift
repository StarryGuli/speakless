import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// 随系统外观（浅色/深色）自动切换的颜色
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
    }
}

enum Theme {
    static let window = Color(light: Color(hex: 0xECECF0), dark: Color(hex: 0x1C1B1D))
    static let sidebar = Color(light: Color(hex: 0xFAFAFC), dark: Color(hex: 0x2B2A2C))
    static let navActive = Color(light: Color(hex: 0xE7E7EC), dark: Color(hex: 0x403F41))
    static let card = Color(light: Color.white, dark: Color(hex: 0x39383A))
    static let cardInner = Color(light: Color(hex: 0xF1F1F5), dark: Color(hex: 0x2E2D2F))
    static let panel = Color(light: Color(hex: 0xF6F6F9), dark: Color(hex: 0x333234))
    static let stroke = Color(light: Color.black.opacity(0.09), dark: Color.white.opacity(0.09))
    static let text = Color(light: Color(hex: 0x1B1B1D), dark: Color(hex: 0xF3F3F4))
    static let secondary = Color(light: Color(hex: 0x76767E), dark: Color(hex: 0xA6A5AA))
    static let accent = Color(hex: 0x5B7BF8)
    static let green = Color(hex: 0x4FB38D)
    static let danger = Color(hex: 0xE5584F)
    static let heat0 = Color(light: Color(hex: 0xE4E4EA), dark: Color(hex: 0x333236))
}

extension View {
    /// `hover`：鼠标指到这张卡片时，边框亮起主色。大块的容器卡（里面还有可点的行）传 false
    @ViewBuilder func cardStyle(radius: CGFloat = 16, hover: Bool = true) -> some View {
        if hover {
            background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card)).hoverBorder(radius: radius, strength: 0.8)
        } else {
            background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
        }
    }

    /// 鼠标指到哪个选项，哪个选项的边框就亮起来（主色细边 + 一圈很淡的光），移开 0.14 秒内淡出
    func hoverBorder(radius: CGFloat = 10, strength: Double = 1) -> some View { modifier(HoverBorder(radius: radius, strength: strength)) }
}

struct HoverBorder: ViewModifier {
    let radius: CGFloat
    let strength: Double
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.accent.opacity(hover ? 0.8 * strength : 0), lineWidth: 1.3)
                    .allowsHitTesting(false)
            )
            .shadow(color: Theme.accent.opacity(hover ? 0.20 * strength : 0), radius: 6)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.14), value: hover)
    }
}

struct KeyChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardInner))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.stroke))
            .hoverBorder(radius: 8, strength: 0.8)
    }
}

/// 自己画的标志：三根声波条。不是任何现有产品的图形。
struct LogoMark: View {
    var color: Color = Theme.accent
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach([9.0, 17.0, 12.0, 6.0], id: \.self) { h in
                Capsule().fill(color).frame(width: 3.2, height: CGFloat(h))
            }
        }
    }
}

/// 浅色圆角胶囊分段选择（All / Dictations / Ask anything 这种）
struct PillTabs: View {
    let items: [String]
    var icons: [String: String] = [:]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                Button(action: { selection = item }) {
                    HStack(spacing: 5) {
                        if let icon = icons[item] {
                            Image(systemName: icon).font(.system(size: 11))
                                .foregroundColor(item == "Auto-added" ? Theme.green : Theme.secondary)
                        }
                        Text(item).font(.system(size: 14, weight: selection == item ? .semibold : .regular))
                    }
                    .foregroundColor(selection == item ? Theme.text : Theme.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(selection == item ? Theme.navActive : Color.clear))
                    .hoverBorder(radius: 17, strength: 0.8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(Theme.stroke))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .hoverBorder(radius: 20, strength: 0.9)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(configuration.isPressed ? Theme.navActive : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.stroke.opacity(2)))
            .hoverBorder(radius: 9)
    }
}


/// 当前窗口有多大。各个页面按它决定排版：窄了就把侧栏收成图标、把右栏挪到下面、让设置项换行。
struct LayoutInfo: Equatable {
    var width: CGFloat = 1080
    var height: CGFloat = 750
    /// 侧栏收成只剩图标（半屏或更窄）
    var compact: Bool { width < 800 }
    /// 非常窄
    var tiny: Bool { width < 560 }
    /// 主内容区能用的宽度（减去侧栏和边距）
    var contentWidth: CGFloat { width - (compact ? 78 + 16 : 202 + 16) - (compact ? 32 : 52) }
}

private struct LayoutKey: EnvironmentKey { static let defaultValue = LayoutInfo() }
extension EnvironmentValues {
    var layout: LayoutInfo {
        get { self[LayoutKey.self] }
        set { self[LayoutKey.self] = newValue }
    }
}

// MARK: - 输入框高亮：光标落在哪个框里，那个框就亮起来

/// 光标在框里：边框换成主色、底色微微泛亮、外面一圈柔光；鼠标放上去：边框略深。过渡 0.15 秒，不跳。
struct FieldHighlight: ViewModifier {
    @FocusState private var focused: Bool
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 9).padding(.vertical, 5.5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(focused ? Theme.accent.opacity(0.09) : Theme.cardInner))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(focused ? Theme.accent : (hover ? Theme.stroke.opacity(2.4) : Theme.stroke.opacity(1.4)), lineWidth: focused ? 1.5 : 1)
            )
            .shadow(color: focused ? Theme.accent.opacity(0.30) : .clear, radius: 5)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.15), value: focused)
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

extension View {
    func fieldHighlight() -> some View { modifier(FieldHighlight()) }
}
