import CoreGraphics
import Foundation

/// Click ripples (BUILD_PLAN §5.4): an expanding, fading ring at each click. Pure — the compositor
/// just draws whatever `active(at:)` returns. Centers are in source pixels, top-left.
struct RippleTrack {
    struct Ripple: Equatable {
        var center: CGPoint
        var progress: Double   // 0 (just clicked) → 1 (faded out)
    }

    let clicks: [CGPoint]
    let times: [Double]
    let lifetime: Double

    init(events: [InputEvent], lifetime: Double = 0.5) {
        var c: [CGPoint] = []
        var t: [Double] = []
        for e in events where e.kind == .click {
            c.append(e.point); t.append(e.t)
        }
        self.clicks = c
        self.times = t
        self.lifetime = lifetime
    }

    func active(at time: Double) -> [Ripple] {
        var out: [Ripple] = []
        for i in clicks.indices {
            let age = time - times[i]
            if age >= 0, age <= lifetime {
                out.append(Ripple(center: clicks[i], progress: age / lifetime))
            }
        }
        return out
    }
}

/// The full bundle of per-frame render signals for a project's current trim window. Built once by
/// `TrackBuilder` and passed to both export and preview so they stay pixel-identical (§5.6).
struct RenderTracks {
    let camera: CameraTrack
    let cursor: CursorTrack
    let ripples: RippleTrack
    /// Drawn cursor size multiplier (Darkroom §2.4 Cursor · Size).
    var cursorScale: Double = 1.4
    /// Burned-in caption lines, already remapped to the edited timeline.
    var captions: CaptionTrack = .empty
}
