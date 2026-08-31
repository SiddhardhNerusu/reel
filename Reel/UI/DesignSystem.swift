import SwiftUI

/// Reel's visual language (the app should look like the clips it makes: dark, calm, one accent).
/// Cool neutrals biased toward the violet accent; coral reserved exclusively for record.
enum RC {
    static let ground     = Color(lightHex: 0xE9EAEF, darkHex: 0x131419)
    static let surface    = Color(lightHex: 0xFFFFFF, darkHex: 0x1B1C22)
    static let surface2   = Color(lightHex: 0xF3F4F8, darkHex: 0x232430)
    static let raised     = Color(lightHex: 0xFFFFFF, darkHex: 0x2A2B35)
    static let text       = Color(lightHex: 0x191A20, darkHex: 0xF1F2F6)
    static let textDim    = Color(lightHex: 0x5E6070, darkHex: 0x9B9CA7)
    static let textFaint  = Color(lightHex: 0x9A9CA8, darkHex: 0x696A76)
    static let accent     = Color(lightHex: 0x6B5BE6, darkHex: 0x8D7DFF)
    static let record     = Color(lightHex: 0xEE463A, darkHex: 0xFF5A4D)
    static let success    = Color(lightHex: 0x1CAE6C, darkHex: 0x41D28D)
    static let canvasInset = Color(lightHex: 0xDEDFE6, darkHex: 0x0E0F13)

    /// Hairline borders adapt automatically (black in light, white in dark).
    static var hairline: Color { Color.primary.opacity(0.09) }
    static var hairlineStrong: Color { Color.primary.opacity(0.16) }
}

enum RM {  // metrics
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 10
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    /// A theme-adaptive color from two hex values.
    init(lightHex: UInt, darkHex: UInt) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? darkHex : lightHex
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Button styles

struct FilledButtonStyle: ButtonStyle {
    var fill: Color
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 15 : 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 16)
            .padding(.vertical, large ? 12 : 9)
            .background(fill.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: large ? 12 : RM.controlRadius))
            .shadow(color: fill.opacity(0.4), radius: 12, y: 5)
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .hoverBrighten()
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 15 : 14, weight: .semibold))
            .foregroundStyle(RC.text)
            .padding(.horizontal, large ? 20 : 15)
            .padding(.vertical, large ? 12 : 9)
            .background(RC.surface2, in: RoundedRectangle(cornerRadius: large ? 12 : RM.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: large ? 12 : RM.controlRadius).stroke(RC.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : (enabled ? 1 : 0.5))
            .hoverBrighten()
    }
}

struct GhostButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 15 : 14, weight: .semibold))
            .foregroundStyle(RC.textDim)
            .padding(.horizontal, large ? 16 : 12)
            .padding(.vertical, large ? 12 : 9)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == FilledButtonStyle {
    static var reelAccent: FilledButtonStyle { FilledButtonStyle(fill: RC.accent) }
    static var reelAccentLarge: FilledButtonStyle { FilledButtonStyle(fill: RC.accent, large: true) }
    static var reelRecord: FilledButtonStyle { FilledButtonStyle(fill: RC.record, large: true) }
}
extension ButtonStyle where Self == SoftButtonStyle {
    static var reelSoft: SoftButtonStyle { SoftButtonStyle() }
}
extension ButtonStyle where Self == GhostButtonStyle {
    static var reelGhost: GhostButtonStyle { GhostButtonStyle() }
    static var reelGhostLarge: GhostButtonStyle { GhostButtonStyle(large: true) }
}

// MARK: - Reusable bits

/// A grouped inspector/section label (small uppercase).
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1)
            .foregroundStyle(RC.textFaint)
    }
}

extension CGSize {
    /// e.g. "2560×1440" — for compact resolution labels.
    var label: String { "\(Int(width.rounded()))×\(Int(height.rounded()))" }
}

/// The app window ground: a deep neutral with a faint accent glow up top, so the surface has
/// depth instead of reading as a flat rectangle.
struct WindowBackground: View {
    var body: some View {
        ZStack {
            RC.ground
            RadialGradient(colors: [RC.accent.opacity(0.13), .clear],
                           center: .init(x: 0.15, y: -0.05), startRadius: 0, endRadius: 560)
                .blendMode(.plusLighter).opacity(0.7)
        }
        .ignoresSafeArea()
    }
}

/// Subtle hover lift for interactive tiles (macOS-app feel).
struct HoverLift: ViewModifier {
    @State private var hovering = false
    var scale: CGFloat = 1.02
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .brightness(hovering ? 0.04 : 0)
            .animation(.easeOut(duration: 0.14), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Hover brightness for buttons (no scale — just a subtle lift on the fill).
struct HoverBrighten: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .brightness(hovering ? 0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Card surface with hairline border + soft shadow for depth.
    func reelCard(padding: CGFloat = 18, radius: CGFloat = RM.cardRadius) -> some View {
        self.padding(padding)
            .background(RC.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(RC.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
    }
    func hoverLift(scale: CGFloat = 1.02) -> some View { modifier(HoverLift(scale: scale)) }
    func hoverBrighten() -> some View { modifier(HoverBrighten()) }
}
