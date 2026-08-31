import Foundation

/// The 1-Euro filter (Casiez et al.) — speed-adaptive smoothing that removes cursor jitter while
/// staying tight on fast, deliberate moves (REVAMP_BRIEF §5.2). Low speed ⇒ heavy smoothing (kills
/// tremor); high speed ⇒ light smoothing (no lag behind a flick to a button). Pure math.
struct OneEuroFilter {
    var minCutoff: Double     // Hz — lower = smoother at rest (verified default 1.0)
    var beta: Double          // speed coupling — higher = less lag when moving fast (verified 0.02)
    var dCutoff: Double       // Hz — cutoff for the derivative estimate (verified 1.0)

    private var xPrev: Double?
    private var dxPrev: Double = 0

    init(minCutoff: Double = 1.0, beta: Double = 0.02, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    mutating func filter(_ x: Double, dt: Double) -> Double {
        guard let xp = xPrev else { xPrev = x; return x }   // seed on first sample (no transient)
        let dt = max(1e-4, dt)
        let dx = (x - xp) / dt
        let aD = alpha(cutoff: dCutoff, dt: dt)
        let dxHat = aD * dx + (1 - aD) * dxPrev
        let cutoff = minCutoff + beta * abs(dxHat)
        let a = alpha(cutoff: cutoff, dt: dt)
        let xHat = a * x + (1 - a) * xp
        xPrev = xHat
        dxPrev = dxHat
        return xHat
    }
}
