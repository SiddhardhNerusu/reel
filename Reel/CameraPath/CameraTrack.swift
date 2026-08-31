import CoreGraphics
import Foundation

/// A dense, random-access camera signal. Precomputed once by the solver at a fixed fps; both
/// PREVIEW and EXPORT sample it via `state(at:)`, which is what makes them pixel-identical
/// (BUILD_PLAN §5.5/§5.6). Random access via linear interpolation between precomputed frames.
struct CameraTrack {
    let states: [CameraState]
    let fps: Double
    let sourceSize: CGSize

    init(states: [CameraState], fps: Int, sourceSize: CGSize) {
        self.states = states
        self.fps = Double(fps)
        self.sourceSize = sourceSize
    }

    static func solve(events: [InputEvent],
                      duration: Double,
                      fps: Int,
                      sourceSize: CGSize,
                      config: SolverConfig = .default) -> CameraTrack {
        let states = CameraPathSolver.solve(events: events, duration: duration, fps: fps,
                                            sourceSize: sourceSize, config: config)
        return CameraTrack(states: states, fps: fps, sourceSize: sourceSize)
    }

    /// Camera at an arbitrary video-timeline time (seconds). Clamped + interpolated.
    func state(at t: Double) -> CameraState {
        guard !states.isEmpty else { return .rest(sourceSize: sourceSize) }
        let x = max(0, t) * fps
        let i = Int(x.rounded(.down))
        if i >= states.count - 1 { return states[states.count - 1] }
        let frac = x - Double(i)
        let a = states[i], b = states[i + 1]
        return CameraState(
            center: CGPoint(x: a.center.x + (b.center.x - a.center.x) * frac,
                            y: a.center.y + (b.center.y - a.center.y) * frac),
            scale: a.scale + (b.scale - a.scale) * frac)
    }
}
