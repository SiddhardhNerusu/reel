import CoreGraphics
import XCTest

/// SP-10 — clustering, viewport clamp, and the coordinate-adapter transform. All pure math;
/// these stay as the regression suite while the feel is tuned (BUILD_PLAN §5.3 / §10).
final class CameraPathTests: XCTestCase {

    private let source = CGSize(width: 2560, height: 1440)

    private func click(_ t: Double, _ x: Double, _ y: Double) -> InputEvent {
        InputEvent(t: t, x: x, y: y, kind: .click, inBounds: true)
    }

    // MARK: Clustering

    func testClusteringHonorsIdleGap() {
        let cfg = SolverConfig()   // idleGap 0.8
        // Two bursts separated by a 2 s idle gap ⇒ exactly two clusters.
        let events = [
            click(0.0, 400, 400), click(0.3, 420, 410), click(0.5, 410, 405),
            click(3.0, 2000, 1000), click(3.2, 2010, 1010),
        ]
        let clusters = CameraPathSolver.clusters(events: events, sourceSize: source, config: cfg)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertLessThan(clusters[0].center.x, clusters[1].center.x)
    }

    func testClusterHonorsMinHold() {
        let cfg = SolverConfig()   // minHold 1.0
        // A single instantaneous click must still hold for minHold.
        let clusters = CameraPathSolver.clusters(events: [click(1.0, 1280, 720)],
                                                 sourceSize: source, config: cfg)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertGreaterThanOrEqual(clusters[0].end - clusters[0].start, cfg.minHold - 1e-9)
    }

    func testOutOfBoundsEventsIgnored() {
        let events = [click(0.0, 400, 400), click(0.1, -50, -50)]   // 2nd is out of bounds…
        var oob = events[1]; oob.inBounds = false
        let clusters = CameraPathSolver.clusters(events: [events[0], oob],
                                                 sourceSize: source, config: .default)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].bbox.width, 0, accuracy: 1e-9)   // only the in-bounds point remains
    }

    // MARK: Viewport clamp

    func testViewportStaysInsideSourceAtEveryScale() {
        for scale in stride(from: 1.0, through: 3.0, by: 0.25) {
            // Push the center hard into a corner; the clamp must pull the viewport back inside.
            let cam = CameraState(center: CGPoint(x: -9999, y: 9_999_999), scale: scale)
            let vp = CameraGeometry.viewport(for: cam, sourceSize: source)
            XCTAssertGreaterThanOrEqual(vp.minX, -1e-6, "viewport left edge escaped at scale \(scale)")
            XCTAssertGreaterThanOrEqual(vp.minY, -1e-6, "viewport top edge escaped at scale \(scale)")
            XCTAssertLessThanOrEqual(vp.maxX, source.width + 1e-6, "viewport right edge escaped at scale \(scale)")
            XCTAssertLessThanOrEqual(vp.maxY, source.height + 1e-6, "viewport bottom edge escaped at scale \(scale)")
        }
    }

    func testScaleClampedToAtLeastOne() {
        let cam = CameraState(center: CGPoint(x: 1280, y: 720), scale: 0.3)
        let vp = CameraGeometry.viewport(for: cam, sourceSize: source)
        // scale<1 is forced to 1 ⇒ viewport equals full source.
        XCTAssertEqual(vp.width, source.width, accuracy: 1e-6)
        XCTAssertEqual(vp.height, source.height, accuracy: 1e-6)
    }

    // MARK: The single coordinate adapter (§5.3 preamble)

    func testCardTransformMapsViewportCornersToContentRect() {
        let output = CGSize(width: 1920, height: 1080)
        let cam = CameraState(center: CGPoint(x: 900, y: 600), scale: 1.8)
        let content = CameraGeometry.contentRect(outputSize: output, sourceSize: source, paddingFraction: 0.06)
        let t = CameraGeometry.cardTransform(camera: cam, sourceSize: source,
                                             contentRect: content, outputSize: output)
        let vpTL = CameraGeometry.viewport(for: cam, sourceSize: source)

        // Convert a top-left source point → CI, apply, convert back to top-left output space.
        func project(_ p: CGPoint) -> CGPoint {
            let ci = CGPoint(x: p.x, y: source.height - p.y).applying(t)
            return CGPoint(x: ci.x, y: output.height - ci.y)
        }
        // The viewport's top-left corner must map to the content rect's top-left corner, etc.
        let tl = project(CGPoint(x: vpTL.minX, y: vpTL.minY))
        let br = project(CGPoint(x: vpTL.maxX, y: vpTL.maxY))
        XCTAssertEqual(tl.x, content.minX, accuracy: 1e-3)
        XCTAssertEqual(tl.y, content.minY, accuracy: 1e-3)
        XCTAssertEqual(br.x, content.maxX, accuracy: 1e-3)
        XCTAssertEqual(br.y, content.maxY, accuracy: 1e-3)
    }

    func testProjectPointHelperAgreesWithManualProjection() {
        let output = CGSize(width: 1920, height: 1080)
        let cam = CameraState(center: CGPoint(x: 1280, y: 720), scale: 2.0)
        let content = CameraGeometry.contentRect(outputSize: output, sourceSize: source, paddingFraction: 0.05)
        let p = CGPoint(x: 1300, y: 700)
        let viaHelper = CameraGeometry.projectPointTopLeft(p, camera: cam, sourceSize: source,
                                                           contentRect: content, outputSize: output)
        let t = CameraGeometry.cardTransform(camera: cam, sourceSize: source, contentRect: content, outputSize: output)
        let ci = CGPoint(x: p.x, y: source.height - p.y).applying(t)
        let manual = CGPoint(x: ci.x, y: output.height - ci.y)
        XCTAssertEqual(viaHelper.x, manual.x, accuracy: 1e-6)
        XCTAssertEqual(viaHelper.y, manual.y, accuracy: 1e-6)
    }

    // MARK: Solve + track integration

    func testSolveProducesInBoundsMonotonicTimeline() {
        let events = [click(1.0, 2000, 1000), click(1.2, 2010, 1010), click(1.4, 1990, 990)]
        let track = CameraTrack.solve(events: events, duration: 4, fps: 60, sourceSize: source)
        XCTAssertEqual(track.states.count, 240)
        // Every solved frame's viewport is inside the source.
        for st in track.states {
            let vp = CameraGeometry.viewport(for: st, sourceSize: source)
            XCTAssertGreaterThanOrEqual(vp.minX, -1e-6)
            XCTAssertLessThanOrEqual(vp.maxX, source.width + 1e-6)
            XCTAssertGreaterThanOrEqual(st.scale, 1.0 - 1e-9)
        }
        // It should actually zoom in around the activity (peak scale > 1).
        let peak = track.states.map(\.scale).max() ?? 1
        XCTAssertGreaterThan(peak, 1.3)
    }

    func testTrackInterpolatesBetweenFrames() {
        let events = [click(1.0, 2000, 1000)]
        let track = CameraTrack.solve(events: events, duration: 3, fps: 60, sourceSize: source)
        let a = track.state(at: 1.000)
        let mid = track.state(at: 1.0 + 0.5 / 60.0)   // halfway between frame 60 and 61
        let b = track.state(at: 1.0 + 1.0 / 60.0)
        // Midpoint scale lies between the two bracketing frames.
        XCTAssertGreaterThanOrEqual(mid.scale, min(a.scale, b.scale) - 1e-9)
        XCTAssertLessThanOrEqual(mid.scale, max(a.scale, b.scale) + 1e-9)
    }

    // Regression: a trimmed export must clip + rebase events to the trim window so the camera
    // stays in sync (confirmed review finding — TrackBuilder).
    func testTrackBuilderClipsAndRebasesToTrimWindow() {
        var project = ReelProject(
            recordingStartTime: 0, duration: 5,
            geometry: GeometrySnapshot.make(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
                                            pointPixelScale: 2))
        project.fps = 60
        project.trimIn = 1
        project.trimOut = 3                      // editedDuration = 2 s
        let events = [
            InputEvent(t: 0.5, x: 100, y: 100, kind: .click, inBounds: true),   // before window → dropped
            InputEvent(t: 2.5, x: 2000, y: 1000, kind: .click, inBounds: true),  // in window → rebased to 1.5s
            InputEvent(t: 4.0, x: 300, y: 300, kind: .click, inBounds: true),    // after window → dropped
        ]
        let camera = TrackBuilder.build(project: project, events: events, cursor: []).camera
        // Frame count reflects the TRIMMED duration, not the raw 5 s.
        XCTAssertEqual(camera.states.count, 120)
        // At the very start of the trimmed clip the camera is ~at rest (the in-window click was at
        // rebased 1.5 s; even with look-ahead it hasn't fired yet at t=0).
        XCTAssertLessThan(camera.state(at: 0).scale, 1.2)
        // It does zoom for the surviving in-window activity.
        XCTAssertGreaterThan(camera.states.map(\.scale).max() ?? 1, 1.3)
    }

    // Click ripples: active only within their lifetime after each click, progress 0→1.
    func testRippleTrackActivation() {
        let events = [click(1.0, 400, 400), click(2.0, 800, 600)]
        let track = RippleTrack(events: events, lifetime: 0.5)
        XCTAssertTrue(track.active(at: 0.5).isEmpty, "no ripple before the first click")
        let atClick = track.active(at: 1.0)
        XCTAssertEqual(atClick.count, 1)
        XCTAssertEqual(atClick[0].progress, 0, accuracy: 1e-9)
        XCTAssertEqual(track.active(at: 1.25).first?.progress ?? -1, 0.5, accuracy: 1e-9)  // half-faded
        XCTAssertTrue(track.active(at: 1.6).isEmpty, "ripple gone after its lifetime")
        XCTAssertEqual(track.active(at: 2.0).count, 1, "second click ripples independently")
    }

    func testRippleTrackIgnoresNonClicks() {
        let events = [InputEvent(t: 1.0, x: 10, y: 10, kind: .scroll, inBounds: true)]
        XCTAssertTrue(RippleTrack(events: events).active(at: 1.0).isEmpty, "scrolls don't ripple")
    }

    // 1-Euro filter: seeds on first sample, converges to a steady input, stays finite under jitter.
    func testOneEuroConvergesAndStable() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.filter(100, dt: 1.0 / 60), 100, accuracy: 1e-9)   // seeded
        for _ in 0..<200 { _ = f.filter(100, dt: 1.0 / 60) }
        XCTAssertEqual(f.filter(100, dt: 1.0 / 60), 100, accuracy: 0.5)
        var g = OneEuroFilter()
        let dts = [1.0/60, 1.0/30, 1.0/120, 1.0/24]
        for i in 0..<400 { let v = g.filter(Double(i % 7) * 30, dt: dts[i % dts.count]); XCTAssertFalse(v.isNaN || v.isInfinite) }
    }

    // Auto-cut: a long idle gap becomes a cut; short gaps are kept.
    func testIdleCutPlannerCutsLongGapsOnly() {
        // Clicks at 0.5 and 8.0 → a ~7s idle gap in a 9s clip; plus a short gap that must survive.
        let cuts = IdleCutPlanner.cuts(eventTimes: [0.5, 8.0, 8.4], duration: 9.0, silence: nil)
        XCTAssertEqual(cuts.count, 1, "exactly the one long gap should be cut")
        XCTAssertGreaterThan(cuts[0].lowerBound, 0.5)
        XCTAssertLessThan(cuts[0].upperBound, 8.0)
        // A demo with steady clicks (no long gap) yields no cuts.
        XCTAssertTrue(IdleCutPlanner.cuts(eventTimes: [0.5, 1.2, 2.0, 2.6], duration: 3.0, silence: nil).isEmpty)
    }

    // TimeRemap: trims + cuts compose; times inside a cut map to nil, others compress.
    func testTimeRemapComposesTrimAndCuts() {
        let r = TimeRemap(trimIn: 1.0, trimOut: 9.0, cuts: [3.0...6.0])   // remove 3s in the middle
        XCTAssertNil(r.output(0.5), "before trimIn ⇒ nil")
        XCTAssertNil(r.output(4.0), "inside a cut ⇒ nil")
        XCTAssertEqual(r.output(2.0)!, 1.0, accuracy: 1e-9)               // 2.0 − trimIn
        XCTAssertEqual(r.output(7.0)!, 7.0 - 1.0 - 3.0, accuracy: 1e-9)   // minus trim + the 3s cut
        XCTAssertEqual(r.editedDuration, (9.0 - 1.0) - 3.0, accuracy: 1e-9)
    }

    // Size-aware zoom (REVAMP_BRIEF §5.2): a small clicked element zooms harder than a large one.
    func testZoomScaleIsSizeAware() {
        let cfg = SolverConfig()
        let small = CGRect(x: 1200, y: 700, width: 120, height: 44)     // a button
        let large = CGRect(x: 200, y: 200, width: 1600, height: 900)    // a big panel
        let sSmall = CameraPathSolver.zoomScale(forRegion: small, sourceSize: source, config: cfg)
        let sLarge = CameraPathSolver.zoomScale(forRegion: large, sourceSize: source, config: cfg)
        XCTAssertGreaterThan(sSmall, sLarge, "small targets should zoom more than large ones")
        XCTAssertGreaterThan(sSmall, 1.5)
    }

    // Skip-zoom: an element that already fills most of the frame should not be zoomed at all.
    func testSkipZoomWhenTargetAlreadyLarge() {
        let cfg = SolverConfig()
        let huge = CGRect(x: 40, y: 40, width: 2400, height: 1360)      // nearly full-frame
        let s = CameraPathSolver.zoomScale(forRegion: huge, sourceSize: source, config: cfg)
        XCTAssertEqual(s, 1.0, accuracy: 1e-9, "already-large targets shouldn't trigger a zoom")
    }

    // A click carrying its element rect frames that element (centered on it, sized to it).
    func testClusterFramesTheClickedElement() {
        var e = click(1.0, 1300, 720)
        e.targetRect = CGRect(x: 1240, y: 690, width: 120, height: 60)
        let clusters = CameraPathSolver.clusters(events: [e], sourceSize: source, config: .default)
        XCTAssertEqual(clusters.count, 1)
        // Centered on the element, not the raw click point.
        XCTAssertEqual(clusters[0].center.x, 1300, accuracy: 40)
        XCTAssertEqual(clusters[0].center.y, 720, accuracy: 40)
        XCTAssertGreaterThan(clusters[0].scale, 1.5, "a small button should zoom in")
    }
}
