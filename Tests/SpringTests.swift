import CoreGraphics
import XCTest

/// SP-10 — the critically-damped spring must never overshoot, must settle in the §5.3 band,
/// and must stay stable under irregular dt. These properties are the auto-zoom's whole feel.
final class SpringTests: XCTestCase {

    func testNoOvershoot() {
        var s = CriticallyDampedSpring(value: 0, omega: 13)
        let target = 100.0
        var maxValue = 0.0
        for _ in 0..<600 { s.step(toward: target, dt: 1.0 / 60.0); maxValue = max(maxValue, s.value) }
        // Critically damped ⇒ approaches monotonically from below, never crosses the target.
        XCTAssertLessThanOrEqual(maxValue, target + 1e-6, "spring overshot its target")
    }

    func testSettlesWithinBand() {
        var s = CriticallyDampedSpring(value: 0, omega: 13)
        let target = 100.0
        let dt = 1.0 / 60.0
        var t = 0.0
        while t < 0.7 { s.step(toward: target, dt: dt); t += dt }
        // Within ~0.7 s a ω≈13 spring should be within 1% of a 100-unit step.
        XCTAssertEqual(s.value, target, accuracy: 1.0, "spring did not settle within 0.7 s")
    }

    func testStableUnderIrregularDt() {
        var s = CriticallyDampedSpring(value: 0, omega: 13)
        let target = 250.0
        // Deterministic but jittery dt in [1/240, 1/15]; no RNG (scripts/tests stay reproducible).
        let jitter: [Double] = [1.0/60, 1.0/30, 1.0/240, 1.0/15, 1.0/90, 1.0/24, 1.0/120, 1.0/45]
        var total = 0.0
        var k = 0
        while total < 2.0 {
            let dt = jitter[k % jitter.count]; k += 1; total += dt
            s.step(toward: target, dt: dt)
            XCTAssertFalse(s.value.isNaN || s.value.isInfinite, "spring diverged")
            XCTAssertLessThanOrEqual(s.value, target + 0.5, "spring overshot under irregular dt")
        }
        XCTAssertEqual(s.value, target, accuracy: 2.0, "spring did not converge under irregular dt")
    }

    func testRetargetMidFlightNoOvershoot() {
        var s = CriticallyDampedSpring(value: 0, omega: 13)
        let dt = 1.0 / 60.0
        // Fly toward 100 for 0.2 s, then retarget to 40 — must not overshoot the new target.
        var t = 0.0
        while t < 0.2 { s.step(toward: 100, dt: dt); t += dt }
        var minAfter = s.value
        t = 0
        while t < 1.0 { s.step(toward: 40, dt: dt); minAfter = min(minAfter, s.value); t += dt }
        XCTAssertGreaterThanOrEqual(minAfter, 40 - 1.0, "spring undershot past the retarget")
    }
}
