import XCTest
@testable import Reel

/// The motion dial must be a real spread (owner: "add more variance"), keep clustering at the
/// verified defaults at its midpoint, and go fully to rest when auto-zoom is off.
final class MotionConfigTests: XCTestCase {

    func testMidpointIsExactlyTheVerifiedDefaults() {
        let mid = ZoomPlan.config(motionDial: 0.5), d = SolverConfig.default
        XCTAssertEqual(mid.idleGap, d.idleGap, accuracy: 0.001)
        XCTAssertEqual(mid.mergeWindow, d.mergeWindow, accuracy: 0.001)
        XCTAssertEqual(mid.minScale, d.minScale, accuracy: 0.001)
        XCTAssertEqual(mid.maxScale, d.maxScale, accuracy: 0.001)
        XCTAssertEqual(mid.minHold, d.minHold, accuracy: 0.001)
        XCTAssertEqual(mid.omega, d.omega, accuracy: 0.001)
        XCTAssertEqual(mid.lead, d.lead, accuracy: 0.001)
    }

    func testCalmToDynamicIsMonotonic() {
        let calm = ZoomPlan.config(motionDial: 0), dyn = ZoomPlan.config(motionDial: 1)
        XCTAssertLessThan(calm.maxScale, dyn.maxScale)
        XCTAssertLessThan(calm.minScale, dyn.minScale)
        XCTAssertGreaterThan(calm.minHold, dyn.minHold)
        XCTAssertLessThan(calm.omega, dyn.omega)
        XCTAssertGreaterThan(dyn.maxScale - calm.maxScale, 0.8, "the spread must be felt")
    }

    func testOffMeansRest() {
        let off = ZoomPlan.config(motionDial: 1, enabled: false)
        XCTAssertEqual(off.minScale, 1)
        XCTAssertEqual(off.maxScale, 1)
    }
}
