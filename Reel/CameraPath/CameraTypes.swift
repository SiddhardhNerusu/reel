import CoreGraphics
import Foundation

/// The camera at one instant: a viewport center in **source pixels (top-left)** + a zoom scale.
/// scale ≥ 1 always (1 = full frame). BUILD_PLAN §5.3.
struct CameraState: Equatable {
    var center: CGPoint
    var scale: Double

    static func rest(sourceSize: CGSize) -> CameraState {
        CameraState(center: CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2), scale: 1)
    }
}

/// A burst of activity grouped from nearby events (§5.3 step 1). The camera holds on this
/// target's center/scale for [start, end], but begins moving at `activationStart` (earlier, so it
/// *arrives* as the action happens — distance-aware look-ahead).
struct ActivityCluster: Equatable {
    var start: Double        // video-timeline seconds of the first event
    var end: Double          // extended to honor min-hold
    var activationStart: Double  // when the camera starts moving toward this target (= start − lead)
    var center: CGPoint      // source pixels, top-left
    var scale: Double        // clamped zoom
    var bbox: CGRect         // source pixels enclosing the cluster's points
}

/// Tunables for the camera-path solve. All feel lives here (§5.3) — SP-10 tests reference these.
struct SolverConfig: Equatable {
    /// Events with an inter-gap below this join one cluster.
    var idleGap: Double = 0.8
    /// Minimum time a zoomed target is held so the camera doesn't pump.
    var minHold: Double = 0.9
    /// Merge two clusters if the gap between them is under this and their targets are close, so the
    /// camera frames both instead of pumping between them (verified: mergeWindow 0.35, radius 0.15·W).
    var mergeWindow: Double = 0.35
    var mergeRadiusFraction: Double = 0.15
    /// Look-ahead: activate a target this long *before* its first event so the camera arrives
    /// as the click happens (§5.3 step 6). Free because we render offline. Distance-aware: a bigger
    /// jump starts a touch earlier (verified defaults: base 0.30, max 0.50).
    var lead: Double = 0.30
    var leadMax: Double = 0.50
    var leadDistGain: Double = 0.20
    /// Zoom range for a cluster; a tight (small-bbox) cluster zooms toward `maxScale`.
    var minScale: Double = 1.4
    var maxScale: Double = 2.2
    /// The activity bbox (plus margin) should fill roughly this fraction of the viewport.
    var coverage: Double = 0.55
    /// Spring snappiness (rad/s).
    var omega: Double = 13
    /// Ignore a new target whose center moves less than this many source px (anti-jitter).
    var minRetargetDistance: Double = 24

    // Size-aware zoom (REVAMP_BRIEF §5.2) --------------------------------------
    /// Pad the clicked element's rect by this factor so it doesn't touch the frame edges.
    var targetPadding: Double = 1.7
    /// Floor for the target size, as a fraction of the source's smaller dimension — so a bare
    /// click point (no element rect) still zooms to a sensible region, not a single pixel.
    var minTargetFraction: Double = 0.16
    /// If the padded target already covers ≥ this fraction of a frame dimension, DON'T zoom
    /// (it's already large/prominent) — the "skip-zoom" rule that stops awkward over-zooming.
    var skipZoomCoverage: Double = 0.72

    static let `default` = SolverConfig()
}
