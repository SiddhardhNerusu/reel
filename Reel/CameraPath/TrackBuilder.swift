import CoreGraphics
import Foundation

/// Builds the camera + cursor tracks for a project's CURRENT trim window (BUILD_PLAN §5.5/§6).
/// Clips events/cursor to [trimIn, trimOut] and rebases their timestamps to the trimmed timeline
/// so the auto-zoom stays in sync after a trim. Used by BOTH export and preview, so they never
/// diverge — the "preview == export" contract (§5.6).
///
/// Darkroom: the camera path goes through `ZoomPlan` (auto clusters merged with the user's
/// overrides), and the project's motion dial / cursor settings feed the solve.
enum TrackBuilder {
    static func build(project: ReelProject,
                      events: [InputEvent],
                      cursor: [CursorSample],
                      cuts: [ClosedRange<Double>] = [],
                      captions: [CaptionLine] = [],
                      config: SolverConfig? = nil) -> RenderTracks {
        // One remap handles trim boundaries AND auto-cut idle spans (cuts default empty ⇒ trim only).
        let remap = TimeRemap(trimIn: project.trimIn, trimOut: project.effectiveTrimOut, cuts: cuts)
        let dur = remap.editedDuration
        let src = project.geometry.sourceSize
        let cfg = config ?? ZoomPlan.config(motionDial: project.motionDial ?? 0.5,
                                            enabled: project.zoomEnabled ?? true)

        let clippedEvents: [InputEvent] = events.compactMap { e in
            guard let nt = remap.output(e.t) else { return nil }
            var c = e; c.t = nt; return c
        }
        let clippedCursor: [CursorSample] = cursor.compactMap { s in
            guard let nt = remap.output(s.t) else { return nil }
            var c = s; c.t = nt; return c
        }

        // Camera: auto clusters + user overrides → segments → spring solve.
        let auto = ZoomPlan.autoClusters(events: clippedEvents, sourceSize: src, config: cfg)
        let segments = ZoomPlan.segments(auto: auto, overrides: project.overrides)
        let camera = ZoomPlan.solveTrack(segments: segments, duration: dur, fps: project.fps,
                                         sourceSize: src, config: cfg)

        // Cursor: smoothing dial 0 (raw) … 1 (silky) → spring omega 60 → 15.
        let smoothing = project.cursorSmoothing ?? 0.75
        let omega = 60.0 - smoothing * 45.0
        let cursorTrack = CursorTrack.build(samples: clippedCursor, duration: dur, fps: project.fps,
                                            sourceSize: src, omega: omega)

        let ripples = (project.clickRipples ?? true) ? RippleTrack(events: clippedEvents)
                                                     : RippleTrack(events: [])

        // Captions ride the same remap so they stay glued to the voice across trims and cuts.
        let clippedCaptions: [CaptionLine] = (project.captionsEnabled ?? false) ? captions.compactMap { line in
            guard let ns = remap.output(line.start) else { return nil }
            let ne = remap.output(line.end) ?? (ns + (line.end - line.start))
            return CaptionLine(start: ns, end: max(ne, ns + 0.2), text: line.text)
        } : []

        return RenderTracks(camera: camera, cursor: cursorTrack, ripples: ripples,
                            cursorScale: project.cursorScale ?? 1.4,
                            captions: CaptionTrack(lines: clippedCaptions))
    }
}
