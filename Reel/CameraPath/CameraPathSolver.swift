import CoreGraphics
import Foundation

/// Turns the discrete event timeline into a smooth per-frame camera signal (BUILD_PLAN §5.3).
/// Entirely pure — this is the moat, and SP-10 tests it before any pixels exist.
enum CameraPathSolver {

    // MARK: Step 1 — activity clustering

    /// Group events whose inter-gap is below `idleGap` into clusters; compute each cluster's
    /// center/scale and extend its end to honor `minHold`.
    static func clusters(events: [InputEvent],
                         sourceSize: CGSize,
                         config: SolverConfig = .default) -> [ActivityCluster] {
        let pts = events
            .filter { $0.inBounds }
            .sorted { $0.t < $1.t }
        guard !pts.isEmpty else { return [] }

        var groups: [[InputEvent]] = []
        var current: [InputEvent] = [pts[0]]
        for e in pts.dropFirst() {
            if e.t - current.last!.t < config.idleGap {
                current.append(e)
            } else {
                groups.append(current)
                current = [e]
            }
        }
        groups.append(current)

        var built: [ActivityCluster] = groups.map { group in
            // Prefer the clicked ELEMENTS' bounds (union) — frames the actual thing you clicked,
            // sized to it. Fall back to the bounding box of the click points.
            let region = targetRegion(for: group)
            let scale = zoomScale(forRegion: region, sourceSize: sourceSize, config: config)
            let center = CameraGeometry.clampCenter(
                CGPoint(x: region.midX, y: region.midY), scale: scale, sourceSize: sourceSize)
            let start = group.first!.t
            let end = max(group.last!.t, start + config.minHold)
            return ActivityCluster(start: start, end: end, activationStart: start,
                                   center: center, scale: scale, bbox: region)
        }

        built = merged(built, sourceSize: sourceSize, config: config)
        built = withLookAhead(built, sourceSize: sourceSize, config: config)
        return built
    }

    /// Merge adjacent clusters that are close in time AND space so the camera frames both rather
    /// than pumping between two nearby targets (anti-pump, REVAMP_BRIEF §5.2).
    static func merged(_ clusters: [ActivityCluster], sourceSize: CGSize, config: SolverConfig) -> [ActivityCluster] {
        guard clusters.count > 1 else { return clusters }
        let radius = sourceSize.width * config.mergeRadiusFraction
        var out: [ActivityCluster] = [clusters[0]]
        for c in clusters.dropFirst() {
            var last = out[out.count - 1]
            let dx = c.center.x - last.center.x, dy = c.center.y - last.center.y
            let near = (dx * dx + dy * dy).squareRoot() < radius
            if c.start - last.end < config.mergeWindow && near {
                let region = last.bbox.union(c.bbox)
                let scale = zoomScale(forRegion: region, sourceSize: sourceSize, config: config)
                last.bbox = region
                last.center = CameraGeometry.clampCenter(CGPoint(x: region.midX, y: region.midY),
                                                         scale: scale, sourceSize: sourceSize)
                last.scale = scale
                last.end = max(last.end, c.end)
                out[out.count - 1] = last
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Distance-aware look-ahead: each cluster starts moving `lead` before its first event (more for
    /// a bigger jump), clamped so it never begins before the previous shot has finished its hold.
    static func withLookAhead(_ clusters: [ActivityCluster], sourceSize: CGSize, config: SolverConfig) -> [ActivityCluster] {
        let diag = (sourceSize.width * sourceSize.width + sourceSize.height * sourceSize.height).squareRoot()
        var prevCenter = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        var prevEnd = 0.0
        return clusters.map { c in
            var c = c
            let dx = c.center.x - prevCenter.x, dy = c.center.y - prevCenter.y
            let dist = (dx * dx + dy * dy).squareRoot()
            let lead = min(config.leadMax, config.lead + config.leadDistGain * min(1, dist / diag))
            c.activationStart = max(prevEnd, c.start - lead, 0)
            prevCenter = c.center
            prevEnd = c.end
            return c
        }
    }

    /// The region the camera should frame for a cluster: the union of the clicked elements' rects
    /// if we resolved any, else the bounding box of the raw click points.
    static func targetRegion(for group: [InputEvent]) -> CGRect {
        let rects = group.compactMap { $0.targetRect }
        if let first = rects.first {
            return rects.dropFirst().reduce(first) { $0.union($1) }
        }
        return boundingBox(group.map { $0.point })
    }

    /// Size-aware zoom (REVAMP_BRIEF §5.2): pad the target, floor its size so a bare point still
    /// gets a sensible frame, SKIP zooming when it's already large, else zoom so the padded target
    /// fits the viewport — clamped to [minScale, maxScale].
    static func zoomScale(forRegion region: CGRect, sourceSize: CGSize, config: SolverConfig) -> Double {
        let floorSize = min(sourceSize.width, sourceSize.height) * config.minTargetFraction
        let w = max(region.width * config.targetPadding, floorSize)
        let h = max(region.height * config.targetPadding, floorSize)
        // Already large/prominent ⇒ don't zoom (avoids awkward over-zoom of a whole panel).
        if max(w / sourceSize.width, h / sourceSize.height) >= config.skipZoomCoverage { return 1.0 }
        let raw = min(sourceSize.width / w, sourceSize.height / h)
        return min(max(raw, config.minScale), config.maxScale)
    }

    // MARK: Step 2 — the step-target signal (with look-ahead)

    /// The camera target at video-timeline time `t`, applying `lead` look-ahead so the camera
    /// arrives *before* the click. Idle ⇒ rest (full frame, centered).
    static func target(at t: Double,
                       clusters: [ActivityCluster],
                       sourceSize: CGSize,
                       config: SolverConfig = .default) -> CameraState {
        // Look-ahead is baked into each cluster's activationStart, so no +lead here.
        if let c = clusters.last(where: { t >= $0.activationStart && t <= $0.end }) {
            return CameraState(center: c.center, scale: c.scale)
        }
        return .rest(sourceSize: sourceSize)
    }

    // MARK: Step 3–5 — spring smooth + clamp, per output frame

    /// Produce a dense per-frame camera signal at `fps` over [0, duration].
    /// Seeds the springs at the first frame's target so we don't ease in from a corner.
    static func solve(events: [InputEvent],
                      duration: Double,
                      fps: Int,
                      sourceSize: CGSize,
                      config: SolverConfig = .default) -> [CameraState] {
        let cl = clusters(events: events, sourceSize: sourceSize, config: config)
        let frameCount = max(1, Int((duration * Double(fps)).rounded(.up)))
        let dt = 1.0 / Double(fps)

        let first = target(at: 0, clusters: cl, sourceSize: sourceSize, config: config)
        var sx = CriticallyDampedSpring(value: first.center.x, omega: config.omega)
        var sy = CriticallyDampedSpring(value: first.center.y, omega: config.omega)
        var ss = CriticallyDampedSpring(value: first.scale, omega: config.omega)

        var out: [CameraState] = []
        out.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let t = Double(i) * dt
            let tgt = target(at: t, clusters: cl, sourceSize: sourceSize, config: config)
            sx.step(toward: tgt.center.x, dt: dt)
            sy.step(toward: tgt.center.y, dt: dt)
            ss.step(toward: tgt.scale, dt: dt)
            // §5.3 step 4: clamp AFTER the spring, scale ≥ 1, viewport inside source.
            let scale = max(1.0, ss.value)
            let center = CameraGeometry.clampCenter(
                CGPoint(x: sx.value, y: sy.value), scale: scale, sourceSize: sourceSize)
            out.append(CameraState(center: center, scale: scale))
        }
        return out
    }

    // MARK: Helpers

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
