import Foundation

/// A critically-damped (ζ=1) spring integrated with semi-implicit Euler and **substepped**
/// so a variable/dropped frame can't make it ring or explode (BUILD_PLAN §5.3).
///
/// ζ=1 ⇒ the response approaches its target monotonically and never overshoots — which is
/// exactly why a spring beats a fixed bezier tween for auto-zoom: mid-flight retargeting is
/// handled for free, with no overshoot. SP-10 pins these properties.
struct CriticallyDampedSpring {
    var value: Double
    var velocity: Double
    /// Angular frequency ω (rad/s). Larger = snappier. Critically-damped 1% settle ≈ 6.64/ω,
    /// so ω≈13 gives ~0.5 s settle (the §5.3 "0.4–0.7 s" band).
    var omega: Double

    init(value: Double = 0, velocity: Double = 0, omega: Double = 13) {
        self.value = value
        self.velocity = velocity
        self.omega = omega
    }

    /// Advance toward `target` by `dt` seconds, substepped to at most `maxSubstep`.
    mutating func step(toward target: Double, dt: Double, maxSubstep: Double = 1.0 / 240.0) {
        guard dt > 0, omega > 0 else { return }
        let k = omega * omega          // stiffness
        let c = 2 * omega              // damping = 2·ζ·ω, ζ=1  ⇒  2·√k = 2·ω
        var remaining = dt
        while remaining > 1e-9 {
            let h = min(maxSubstep, remaining)
            velocity += (-k * (value - target) - c * velocity) * h
            value += velocity * h
            remaining -= h
        }
    }

    /// Snap instantly (used to seed the very first frame at its target so we don't ease in from 0).
    mutating func reset(to v: Double) { value = v; velocity = 0 }
}
