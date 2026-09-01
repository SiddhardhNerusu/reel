import SwiftUI

/// Reel's visual language — "Darkroom" (IMPLEMENTATION_BRIEF v1, artboards 1a–1g).
/// Warm graphite, one amber accent, red only when live. EVERY color/size in the app
/// comes from here; no hex literals anywhere else (brief §4.1).
enum RC {

    // MARK: Color (§1.1 — dark only, warm graphite)

    static let stage     = Color(hex: 0x141210)   // editor canvas, export backdrop
    static let base      = Color(hex: 0x191715)   // window background
    static let raised    = Color(hex: 0x201D1A)   // cards, rows, hover fills, popovers
    static let field     = Color(hex: 0x141210)   // text-field wells

    static let hairline      = Color.white.opacity(0.08)
    static let hairlinePop   = Color.white.opacity(0.10)  // popover border
    static let hairlineSoft  = Color.white.opacity(0.065)

    static let ink  = Color(hex: 0xF3EEE5)
    static let ink2 = Color(hex: 0xF3EEE5).opacity(0.55)
    static let ink3 = Color(hex: 0xF3EEE5).opacity(0.40)
    static let ink4 = Color(hex: 0xF3EEE5).opacity(0.32)

    static let amber        = Color(hex: 0xE2A33E)
    static let amberWash    = Color(hex: 0xE2A33E).opacity(0.14)
    static let amberBorder  = Color(hex: 0xE2A33E).opacity(0.50)
    static let amberInk     = Color(hex: 0x1C1710)
    static let amberHover   = Color(hex: 0xECB455)
    static let amberPressed = Color(hex: 0xC98F31)

    static let live = Color(hex: 0xE5484D)        // recording ONLY

    // MARK: Type (§1.2)

    static let hero       = Font.system(size: 27, weight: .semibold)
    static let title      = Font.system(size: 19, weight: .semibold)
    static let panelTitle = Font.system(size: 16, weight: .semibold)
    static let body       = Font.system(size: 13)
    static let label      = Font.system(size: 12, weight: .semibold)
    static let caption    = Font.system(size: 11)
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Radii (§1.4)

    static let rChip: CGFloat = 6
    static let rButton: CGFloat = 9
    static let rCard: CGFloat = 12
    static let rHero: CGFloat = 14
    static let rLarge: CGFloat = 16
}

// MARK: - Color helper

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension CGSize {
    /// e.g. "2560×1440" — for compact resolution labels.
    var label: String { "\(Int(width.rounded()))×\(Int(height.rounded()))" }
}

// MARK: - Section header (§1.2 sectionCaps)

struct SectionCaps: View {
    let text: String
    var size: CGFloat = 11
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(size * 0.08)
            .foregroundStyle(RC.ink4)
    }
}

// MARK: - Buttons

/// Primary: amber fill, amberInk text (§1.1). Hover raise 1pt (§1.6).
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(RC.amberInk)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(configuration.isPressed ? RC.amberPressed : (hovering ? RC.amberHover : RC.amber),
                        in: RoundedRectangle(cornerRadius: height > 38 ? 11 : RC.rButton))
            .offset(y: hovering && !configuration.isPressed ? -1 : 0)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Secondary: hairline border, raised on hover.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(RC.ink)
            .padding(.horizontal, 15)
            .frame(height: height)
            .background(hovering ? RC.raised : .clear, in: RoundedRectangle(cornerRadius: RC.rButton))
            .overlay(RoundedRectangle(cornerRadius: RC.rButton).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .offset(y: hovering && !configuration.isPressed ? -1 : 0)
            .opacity(configuration.isPressed ? 0.8 : (enabled ? 1 : 0.45))
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Ink-filled (record button on launcher, Grant…, Activate — §2.1/§2.2/§2.6).
struct InkButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var fontSize: CGFloat = 12
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(RC.base)
            .padding(.horizontal, 15)
            .frame(height: height)
            .background(RC.ink.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: 8))
            .offset(y: hovering && !configuration.isPressed ? -1 : 0)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Quiet text button.
struct QuietButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(hovering ? RC.ink2 : RC.ink3)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var reelPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var reelPrimaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(height: 42) }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var reelSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
extension ButtonStyle where Self == InkButtonStyle {
    static var reelInk: InkButtonStyle { InkButtonStyle() }
}
extension ButtonStyle where Self == QuietButtonStyle {
    static var reelQuiet: QuietButtonStyle { QuietButtonStyle() }
}

// MARK: - Chip (aspect / export options — §2.4/§2.5)

struct Chip: View {
    let text: String
    let selected: Bool
    var height: CGFloat = 28
    var mono = false
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(mono ? RC.mono(11.5, weight: selected ? .semibold : .medium)
                           : .system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? RC.amber : RC.ink2)
                .padding(.horizontal, 11)
                .frame(height: height)
                .background(selected ? RC.amberWash : (hovering ? RC.raised : .clear),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? RC.amberBorder : RC.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Toggle (§2.6 spec, used everywhere)

struct ReelToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? RC.amber : Color.white.opacity(0.12))
                    .frame(width: 34, height: 20)
                Circle().fill(isOn ? RC.amberInk : RC.ink.opacity(0.60))
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Slider (§2.4 spec: 4pt track, amber fill, 14pt ink knob)

struct ReelSlider: View {
    @Binding var value: Double        // 0…1
    var onEditingChanged: ((Bool) -> Void)? = nil
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width - 14, 1)
            let x = CGFloat(value.clamped01) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 4)
                Capsule().fill(RC.amber).frame(width: x + 7, height: 4)
                Circle()
                    .fill(RC.ink)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .scaleEffect(hovering || dragging ? 1.15 : 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onEditingChanged?(true) }
                    value = Double(((g.location.x - 7) / w)).clamped01
                }
                .onEnded { _ in dragging = false; onEditingChanged?(false) })
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

private extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}

// MARK: - Keycap (shortcut chips — §2.1/§2.6)

struct Keycap: View {
    let text: String
    var size: CGFloat = 11.5
    var body: some View {
        Text(text)
            .font(RC.mono(size))
            .foregroundStyle(RC.ink2)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(RC.hairline, lineWidth: 1))
    }
}

// MARK: - Hover helpers (§1.6)

struct HoverRaise: ViewModifier {
    @State private var hovering = false
    var dy: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .offset(y: hovering ? dy : 0)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverRaise(_ dy: CGFloat = -1) -> some View { modifier(HoverRaise(dy: dy)) }

    /// L1 card: raised fill + hairline border (§1.5).
    func darkCard(padding: CGFloat = 16, radius: CGFloat = RC.rCard) -> some View {
        self.padding(padding)
            .background(RC.raised, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(RC.hairline, lineWidth: 1))
    }
}

// MARK: - Pulsing record dot (§1.6)

struct PulsingDot: View {
    var size: CGFloat = 10
    var active = true
    @State private var dim = false
    var body: some View {
        Circle().fill(RC.live)
            .frame(width: size, height: size)
            .opacity(active ? (dim ? 0.3 : 1) : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
