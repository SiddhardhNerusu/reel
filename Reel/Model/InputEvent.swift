import CoreGraphics
import Foundation

/// A significant input event on the **video timeline** (seconds since first video frame, §6)
/// in **source pixel space, top-left** (§5.3). Plain mouse-moves live in `cursor.json`, not here.
struct InputEvent: Codable, Equatable {
    enum Kind: String, Codable { case click, scroll, drag, key }

    var t: Double          // video-timeline seconds
    var x: Double          // source pixels, top-left
    var y: Double
    var kind: Kind
    var inBounds: Bool      // false ⇒ landed outside captured rect; stored but ignored by the solver
    /// The clicked UI element's bounds in source pixels, resolved at record time via the
    /// Accessibility hit-test (→ Vision/OCR fallback). nil ⇒ unknown; the solver frames a padded
    /// box around the point instead. This is what lets the camera zoom to the *element* you clicked,
    /// sized to it, rather than a blind fixed-radius box (REVAMP_BRIEF §5.2).
    var targetRect: CGRect? = nil

    var point: CGPoint { CGPoint(x: x, y: y) }
}

/// Dense cursor track sampled during recording (~60 Hz). Source pixels, top-left, video timeline.
struct CursorSample: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
    var point: CGPoint { CGPoint(x: x, y: y) }
}

/// Window-capture only (§5.2 moved-window fix): the captured window's frame sampled ~10 Hz,
/// so an event mid-drag resolves against the nearest frame. Global points, top-left.
struct WindowSample: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
