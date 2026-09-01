import CoreGraphics
import Foundation

/// Presentation theme for the offline composite (BUILD_PLAN §5.4). Pure/Codable — no AppKit
/// colors here so this compiles into the (device-free) test target.
struct RGBAColor: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    static let white = RGBAColor(1, 1, 1)
    static let black = RGBAColor(0, 0, 0)
}

enum BackgroundStyle: Codable, Equatable {
    case solid(RGBAColor)
    case linearGradient(from: RGBAColor, to: RGBAColor, angleDegrees: Double)
    case image(path: String)
}

/// Output aspect ratio. `.source` keeps the captured ratio (no letterboxing).
enum AspectPreset: String, Codable, CaseIterable {
    case source, r16x9, r4x3, r1x1, r9x16

    /// width/height, or nil for `.source`.
    var ratio: Double? {
        switch self {
        case .source: return nil
        case .r16x9:  return 16.0 / 9.0
        case .r4x3:   return 4.0 / 3.0
        case .r1x1:   return 1.0
        case .r9x16:  return 9.0 / 16.0
        }
    }

    var label: String {
        switch self {
        case .source: return "Source"
        case .r16x9:  return "16:9"
        case .r4x3:   return "4:3"
        case .r1x1:   return "1:1"
        case .r9x16:  return "9:16"
        }
    }
}

struct ShadowStyle: Codable, Equatable {
    var blurRadius: Double = 32      // §5.4: 24–40
    var offsetY: Double = 10
    var opacity: Double = 0.35
}

struct Theme: Codable, Equatable {
    /// Fraction of the smaller output dimension used as padding around the screen card (0…0.5).
    var paddingFraction: Double = 0.06
    /// Card corner radius in output pixels.
    var cornerRadius: Double = 18
    var shadow: ShadowStyle = ShadowStyle()
    var background: BackgroundStyle = .linearGradient(
        from: RGBAColor(0.36, 0.40, 0.98),
        to:   RGBAColor(0.60, 0.34, 0.92),
        angleDegrees: 135)
    var aspect: AspectPreset = .source
    /// Whether the auto-zoom scales the whole frame (`false`) or only the screen card (`true`).
    var contentOnlyZoom: Bool = true

    static let `default` = Theme()

    /// Stable key for render caches — covers exactly the fields the static base layer (background
    /// + shadow) depends on. Card geometry/size are keyed separately by the caller.
    var cacheKey: String {
        let bg: String
        switch background {
        case let .solid(c): bg = "s\(c.r),\(c.g),\(c.b),\(c.a)"
        case let .linearGradient(f, t, a): bg = "g\(f.r),\(f.g),\(f.b),\(f.a)-\(t.r),\(t.g),\(t.b),\(t.a)@\(a)"
        case let .image(p): bg = "i\(p)"
        }
        return "\(bg)|\(shadow.blurRadius),\(shadow.offsetY),\(shadow.opacity)|\(cornerRadius)"
    }
}
