import Foundation

/// The Darkroom background catalog (IMPLEMENTATION_BRIEF §2.4). Pure/Codable-friendly so it stays
/// in the device-free Model layer; the editor offers these as one-tap backgrounds.
enum ThemePresets {
    struct Named: Identifiable {
        var id: String { name }
        let name: String
        let background: BackgroundStyle
    }

    private static func hexColor(_ hex: UInt) -> RGBAColor {
        RGBAColor(Double((hex >> 16) & 0xFF) / 255,
                  Double((hex >> 8) & 0xFF) / 255,
                  Double(hex & 0xFF) / 255)
    }

    /// Brief §2.4: presets 1–4 radial gradients, 5–6 solids.
    static let all: [Named] = [
        Named(name: "Dusk",  background: .radialGradient(from: hexColor(0x33415C), to: hexColor(0x332B34))),
        Named(name: "Iris",  background: .radialGradient(from: hexColor(0x5C4A63), to: hexColor(0x2F2A38))),
        Named(name: "Ember", background: .radialGradient(from: hexColor(0xB4785A), to: hexColor(0x3A2F35))),
        Named(name: "Moss",  background: .radialGradient(from: hexColor(0x3F6A5C), to: hexColor(0x262A28))),
        Named(name: "Bone",  background: .solid(hexColor(0xE8E4DC))),
        Named(name: "Coal",  background: .solid(hexColor(0x141210))),
    ]

    /// Return a copy of `theme` with the preset's background applied.
    static func apply(_ preset: Named, to theme: Theme) -> Theme {
        var t = theme
        t.background = preset.background
        return t
    }

    /// Index of the preset whose background matches `theme`, else -1 (custom).
    static func index(matching theme: Theme) -> Int {
        all.firstIndex { $0.background == theme.background } ?? -1
    }
}
