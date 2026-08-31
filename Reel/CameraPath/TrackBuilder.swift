import CoreGraphics
import Foundation

/// Builds the camera + cursor tracks for a project's CURRENT trim window (BUILD_PLAN §5.5/§6).
/// Clips events/cursor to [trimIn, trimOut] and rebases their timestamps to the trimmed timeline
/// so the auto-zoom stays in sync after a trim. Used by BOTH export and (when wired) preview, so
/// they never diverge — the "preview == export" contract (§5.6).
enum TrackBuilder {
    static func build(project: ReelProject,
                      events: [InputEvent],
                      cursor: [CursorSample],
                      cuts: [ClosedRange<Double>] = [],
                      config: SolverConfig = .default) -> RenderTracks {
        // One remap handles trim boundaries AND auto-cut idle spans (cuts default empty ⇒ trim only).
        let remap = TimeRemap(trimIn: project.trimIn, trimOut: project.effectiveTrimOut, cuts: cuts)
        let dur = remap.editedDuration
        let src = project.geometry.sourceSize

        let clippedEvents: [InputEvent] = events.compactMap { e in
            guard let nt = remap.output(e.t) else { return nil }
            var c = e; c.t = nt; return c
        }
        let clippedCursor: [CursorSample] = cursor.compactMap { s in
            guard let nt = remap.output(s.t) else { return nil }
            var c = s; c.t = nt; return c
        }

        let camera = CameraTrack.solve(events: clippedEvents, duration: dur, fps: project.fps,
                                       sourceSize: src, config: config)
        let cursorTrack = CursorTrack.build(samples: clippedCursor, duration: dur, fps: project.fps,
                                            sourceSize: src)
        let ripples = RippleTrack(events: clippedEvents)
        return RenderTracks(camera: camera, cursor: cursorTrack, ripples: ripples)
    }
}
