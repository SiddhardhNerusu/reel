import CoreGraphics
import Foundation

/// A smoothed, random-access cursor signal in **source pixels, top-left** (BUILD_PLAN §5.4:
/// "smooth the cursor track with the same spring"). Prebuilt densely at output fps so preview
/// and export agree.
struct CursorTrack {
    let points: [CGPoint]     // one per output frame
    let fps: Double

    /// Build by resampling raw cursor samples onto an fps grid, then spring-smoothing.
    static func build(samples: [CursorSample],
                      duration: Double,
                      fps: Int,
                      sourceSize: CGSize,
                      omega: Double = 22) -> CursorTrack {
        let frameCount = max(1, Int((duration * Double(fps)).rounded(.up)))
        let dt = 1.0 / Double(fps)
        let sorted = samples.sorted { $0.t < $1.t }

        // Nearest-hold resample of the raw track (cursor doesn't teleport, hold is fine).
        func rawPoint(at t: Double) -> CGPoint {
            guard let first = sorted.first else { return CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2) }
            if t <= first.t { return first.point }
            if t >= sorted.last!.t { return sorted.last!.point }
            // binary search for the last sample ≤ t
            var lo = 0, hi = sorted.count - 1, idx = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if sorted[mid].t <= t { idx = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            let a = sorted[idx], b = sorted[min(idx + 1, sorted.count - 1)]
            let span = b.t - a.t
            guard span > 1e-9 else { return a.point }
            let f = (t - a.t) / span
            return CGPoint(x: a.point.x + (b.point.x - a.point.x) * f,
                           y: a.point.y + (b.point.y - a.point.y) * f)
        }

        // 1-Euro de-jitter (speed-adaptive) — smooth at rest, tight on fast moves (REVAMP_BRIEF §5.2).
        var fx = OneEuroFilter()
        var fy = OneEuroFilter()
        var out: [CGPoint] = []
        out.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let t = Double(i) * dt
            let p = rawPoint(at: t)
            out.append(CGPoint(x: fx.filter(p.x, dt: dt), y: fy.filter(p.y, dt: dt)))
        }
        return CursorTrack(points: out, fps: Double(fps))
    }

    func point(at t: Double) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let x = max(0, t) * fps
        let i = Int(x.rounded(.down))
        if i >= points.count - 1 { return points[points.count - 1] }
        let frac = x - Double(i)
        let a = points[i], b = points[i + 1]
        return CGPoint(x: a.x + (b.x - a.x) * frac, y: a.y + (b.y - a.y) * frac)
    }
}
