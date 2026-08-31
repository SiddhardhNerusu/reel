import Foundation

/// A small catalog of ready-made looks (BUILD_PLAN §5.4/M4). Pure/Codable-friendly so it stays in
/// the device-free Model layer; the editor offers these as one-tap backgrounds.
enum ThemePresets {
    struct Named: Identifiable {
        var id: String { name }
        let name: String
        let background: BackgroundStyle
    }

    static let all: [Named] = [
        Named(name: "Indigo", background: .linearGradient(
            from: RGBAColor(0.36, 0.40, 0.98), to: RGBAColor(0.60, 0.34, 0.92), angleDegrees: 135)),
        Named(name: "Sunset", background: .linearGradient(
            from: RGBAColor(0.98, 0.55, 0.35), to: RGBAColor(0.90, 0.30, 0.52), angleDegrees: 135)),
        Named(name: "Mint", background: .linearGradient(
            from: RGBAColor(0.22, 0.80, 0.68), to: RGBAColor(0.20, 0.55, 0.85), angleDegrees: 135)),
        Named(name: "Graphite", background: .solid(RGBAColor(0.12, 0.13, 0.16))),
        Named(name: "Paper", background: .solid(RGBAColor(0.93, 0.93, 0.95))),
    ]

    /// Return a copy of `theme` with the preset's background applied.
    static func apply(_ preset: Named, to theme: Theme) -> Theme {
        var t = theme
        t.background = preset.background
        return t
    }

    /// Index of the preset whose background matches `theme`, else 0.
    static func index(matching theme: Theme) -> Int {
        all.firstIndex { $0.background == theme.background } ?? 0
    }
}
