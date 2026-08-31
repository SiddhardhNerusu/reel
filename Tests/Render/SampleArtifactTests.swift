import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Not a real test — a convenience to RENDER a watchable sample so you can eyeball the auto-zoom,
/// background, rounded corners, and smooth cursor without any capture permission. It only does work
/// when REEL_WRITE_SAMPLE=1 is set, so normal test runs skip it. Produces:
///   ~/Desktop/DemoRecorder/sample_demo.mp4
///
/// Run with:
///   REEL_WRITE_SAMPLE=1 xcodebuild -project Reel.xcodeproj -scheme ReelRenderTests \
///     -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
final class SampleArtifactTests: XCTestCase {

    func testWriteWatchableSample() async throws {
        guard ProcessInfo.processInfo.environment["REEL_WRITE_SAMPLE"] == "1" else {
            throw XCTSkip("set REEL_WRITE_SAMPLE=1 to render the sample artifact")
        }

        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/488/DemoRecorder")
        let projDir = base.appendingPathComponent("sample_demo.reelproj")
        let outURL = base.appendingPathComponent("sample_demo.mp4")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let raw = projDir.appendingPathComponent(ReelDocument.rawMovieName)

        let sample = try await SyntheticSource.make(to: raw, size: CGSize(width: 1280, height: 720),
                                                    duration: 3.2, fps: 60)
        var project = ReelProject(recordingStartTime: 0, duration: sample.duration, geometry: sample.geometry)
        project.fps = 60
        let doc = ReelDocument(url: projDir, project: project,
                               events: sample.events, cursor: sample.cursor, window: [])
        try doc.writeSidecars()

        let compositor = Compositor()
        let tracks = TrackBuilder.build(project: project, events: sample.events, cursor: sample.cursor)
        let exporter = Exporter(compositor: compositor)
        try await exporter.exportVideo(document: doc, tracks: tracks, to: outURL,
                                       settings: .init(outputSize: CGSize(width: 1280, height: 720), fps: 60))

        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        print("[sample] wrote \(outURL.path)")

        // Dump two frames so the composite can be eyeballed: an idle (rest) frame and a
        // zoomed-in-on-click frame.
        try await dumpFrame(from: outURL, at: 0.10, to: base.appendingPathComponent("sample_frame_rest.png"))
        try await dumpFrame(from: outURL, at: 1.05, to: base.appendingPathComponent("sample_frame_zoom.png"))
        try await dumpFrame(from: outURL, at: 0.72, to: base.appendingPathComponent("sample_frame_ripple.png"))
    }

    private func dumpFrame(from url: URL, at seconds: Double, to png: URL) async throws {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cg = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        guard let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("[sample] wrote \(png.lastPathComponent)")
    }
}
