import CoreGraphics
import Foundation

/// The editable zoom plan (Darkroom editor, IMPLEMENTATION_BRIEF §2.4): the solver's auto
/// clusters merged with the user's `CameraOverride`s into a list of ZOOM SEGMENTS — the blocks
/// on the timeline. Pure math, unit-testable, shared by the editor UI and the render path so a
/// dragged block and the exported camera can never disagree.
///
/// Override semantics (persisted in project.json → overrides):
///  - `.delete` + clusterIndex   — suppress auto cluster i.
///  - `.move`   + clusterIndex   — re-time (`time` = new start, `duration`), re-aim
///                                 (`centerX/Y`), re-scale (`scale`) auto cluster i.
///                                 Nil fields keep the auto value.
///  - `.add`    (+ time/duration/center/scale) — a user-created segment.
struct ZoomSegment: Identifiable, Equatable {
    /// Stable identity: "auto-<clusterIndex>" or "custom-<uuid>".
    let id: String
    var start: Double        // video-timeline seconds (block's left edge)
    var duration: Double
    var center: CGPoint      // source pixels, top-left
    var scale: Double
    var clusterIndex: Int?   // nil ⇒ user-added
    var end: Double { start + duration }
}

enum ZoomPlan {

    /// The auto clusters for the CURRENT trimmed timeline (same pipeline the solver uses).
    static func autoClusters(events: [InputEvent], sourceSize: CGSize,
                             config: SolverConfig = .default) -> [ActivityCluster] {
        CameraPathSolver.clusters(events: events, sourceSize: sourceSize, config: config)
    }

    /// Merge overrides over the auto clusters → the segments the timeline shows.
    static func segments(auto: [ActivityCluster],
                         overrides: [CameraOverride]) -> [ZoomSegment] {
        var out: [ZoomSegment] = []
        for (i, c) in auto.enumerated() {
            if overrides.contains(where: { $0.action == .delete && $0.clusterIndex == i }) { continue }
            var seg = ZoomSegment(id: "auto-\(i)", start: c.start, duration: max(0.2, c.end - c.start),
                                  center: c.center, scale: c.scale, clusterIndex: i)
            if let mv = overrides.last(where: { $0.action == .move && $0.clusterIndex == i }) {
                seg.start = mv.time
                if let d = mv.duration { seg.duration = max(0.2, d) }
                if let x = mv.centerX, let y = mv.centerY { seg.center = CGPoint(x: x, y: y) }
                if let s = mv.scale { seg.scale = s }
            }
            // A fully un-zoomed cluster (scale 1 = "skip zoom") isn't a block.
            if seg.scale > 1.01 { out.append(seg) }
        }
        for ov in overrides where ov.action == .add {
            guard let x = ov.centerX, let y = ov.centerY else { continue }
            out.append(ZoomSegment(id: "custom-\(ov.id.uuidString)",
                                   start: ov.time, duration: max(0.2, ov.duration ?? 1.2),
                                   center: CGPoint(x: x, y: y),
                                   scale: ov.scale ?? 1.8, clusterIndex: nil))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Convert segments back into clusters for the spring solve. Look-ahead is re-derived from
    /// the config (the same distance-aware lead the auto path uses).
    static func clusters(from segments: [ZoomSegment], sourceSize: CGSize,
                         config: SolverConfig = .default) -> [ActivityCluster] {
        var prevCenter = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        var out: [ActivityCluster] = []
        for seg in segments {
            let dist = hypot(seg.center.x - prevCenter.x, seg.center.y - prevCenter.y)
            let norm = dist / max(1, min(sourceSize.width, sourceSize.height))
            let lead = min(config.leadMax, config.lead + norm * config.leadDistGain)
            out.append(ActivityCluster(start: seg.start, end: seg.end,
                                       activationStart: max(0, seg.start - lead),
                                       center: seg.center, scale: seg.scale,
                                       bbox: CGRect(origin: seg.center, size: .zero)))
            prevCenter = seg.center
        }
        return out
    }

    /// Spring-solve a camera track directly from segments (the editor's path — auto solve merged
    /// with user edits). Mirrors `CameraPathSolver.solve` exactly, target-signal swapped.
    static func solveTrack(segments: [ZoomSegment], duration: Double, fps: Int,
                           sourceSize: CGSize, config: SolverConfig = .default) -> CameraTrack {
        let cl = clusters(from: segments, sourceSize: sourceSize, config: config)
        let frameCount = max(1, Int((duration * Double(fps)).rounded(.up)))
        let dt = 1.0 / Double(fps)
        let first = CameraPathSolver.target(at: 0, clusters: cl, sourceSize: sourceSize, config: config)
        var sx = CriticallyDampedSpring(value: first.center.x, omega: config.omega)
        var sy = CriticallyDampedSpring(value: first.center.y, omega: config.omega)
        var ss = CriticallyDampedSpring(value: first.scale, omega: config.omega)
        var states: [CameraState] = []
        states.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let t = Double(i) * dt
            let tgt = CameraPathSolver.target(at: t, clusters: cl, sourceSize: sourceSize, config: config)
            sx.step(toward: tgt.center.x, dt: dt)
            sy.step(toward: tgt.center.y, dt: dt)
            ss.step(toward: tgt.scale, dt: dt)
            let scale = max(1.0, ss.value)
            let center = CameraGeometry.clampCenter(
                CGPoint(x: sx.value, y: sy.value), scale: scale, sourceSize: sourceSize)
            states.append(CameraState(center: center, scale: scale))
        }
        return CameraTrack(states: states, fps: fps, sourceSize: sourceSize)
    }

    /// One dial: zoom speed, ease and hold, tuned together (§2.4 Motion). 0 calm … 1 dynamic.
    /// One dial with a REAL spread (owner feedback: the old range all felt like "too much").
    /// Calm = fewer, gentler zooms that linger; Dynamic = tighter, faster, more of them.
    static func config(motionDial: Double, enabled: Bool = true) -> SolverConfig {
        var c = SolverConfig.default
        guard enabled else {
            c.minScale = 1; c.maxScale = 1        // camera stays at rest — no zoom at all
            return c
        }
        // Symmetric around the MIDPOINT, which is exactly the verified SolverConfig defaults —
        // the render smoke test pins that. Widening clustering further than this merges distant
        // clicks into one frame-sized bbox that trips the skip-zoom rule ("calm" ⇒ no zoom).
        let k = min(1, max(0, motionDial)) - 0.5          // −0.5 (calm) … +0.5 (dynamic)
        let d0 = SolverConfig.default
        c.minScale = d0.minScale + k * 0.6                 // 1.1× … 1.7×
        c.maxScale = d0.maxScale + k * 1.2                 // 1.6× … 2.8×
        c.idleGap = d0.idleGap - k * 0.3                   // 0.95 … 0.65
        c.mergeWindow = d0.mergeWindow - k * 0.2           // 0.45 … 0.25
        c.minHold = d0.minHold - k * 1.2                   // 1.5 s … 0.3 s
        c.omega = d0.omega + k * 14                        // 6 (glide) … 20 (snap)
        c.lead = d0.lead - k * 0.2                         // 0.40 … 0.20
        return c
    }
}
