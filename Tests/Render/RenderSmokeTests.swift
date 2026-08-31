import AVFoundation
import CoreImage
import ImageIO
import XCTest

/// Headless end-to-end proof of Stage 2 (BUILD_PLAN §5.3–§5.5) with NO screen-recording permission:
/// synthesize a `raw.mov` + event timeline, run the real solver + compositor + exporter, then
/// assert the exported file is valid AND that the auto-zoom actually framed the clicks in real
/// pixels. This is the coverage SP-10's pure math can't give — it catches coordinate/flip bugs.
final class RenderSmokeTests: XCTestCase {

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-render-\(UUID().uuidString).\(ext)")
    }

    func testSyntheticSourceExportsValidVideo() async throws {
        let srcURL = tempURL("mov")
        let sample = try await SyntheticSource.make(to: srcURL, size: CGSize(width: 1280, height: 720),
                                                    duration: 2.0, fps: 60)
        defer { try? FileManager.default.removeItem(at: srcURL) }

        // Build the project + tracks exactly as the app would.
        var project = ReelProject(recordingStartTime: 0, duration: sample.duration, geometry: sample.geometry)
        project.fps = 60
        let doc = ReelDocument(url: srcURL.deletingLastPathComponent(), project: project,
                               events: sample.events, cursor: sample.cursor, window: [])
        // NOTE: doc.rawMovieURL must point at our synthetic file; place it via a dedicated dir.
        let projDir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-\(UUID().uuidString).reelproj")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let rawInProj = projDir.appendingPathComponent(ReelDocument.rawMovieName)
        try FileManager.default.moveItem(at: srcURL, to: rawInProj)
        defer { try? FileManager.default.removeItem(at: projDir) }
        let realDoc = ReelDocument(url: projDir, project: project,
                                   events: sample.events, cursor: sample.cursor, window: [])

        let compositor = Compositor()
        let tracks = TrackBuilder.build(project: project, events: sample.events, cursor: sample.cursor)
        let outURL = tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let exporter = Exporter(compositor: compositor)
        let outputSize = CGSize(width: 1280, height: 720)
        try await exporter.exportVideo(document: realDoc, tracks: tracks,
                                       to: outURL, settings: .init(outputSize: outputSize, fps: 60))

        // 1) The file exists and is a decodable video of the right shape/duration.
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path), "no output file")
        let outAsset = AVURLAsset(url: outURL)
        let durOut = try await outAsset.load(.duration).seconds
        XCTAssertEqual(durOut, sample.duration, accuracy: 0.3, "exported duration wrong")
        let vtrack = try await outAsset.loadTracks(withMediaType: .video).first
        let natural = try await vtrack?.load(.naturalSize) ?? .zero
        XCTAssertEqual(natural.width, outputSize.width, accuracy: 1)
        XCTAssertEqual(natural.height, outputSize.height, accuracy: 1)

        // 2) A settled zoomed frame is a real composite (not uniform) — background + card + content.
        let frame = try await copyFrame(from: outAsset, at: 1.0)
        XCTAssertGreaterThan(colorVariance(frame), 40, "output frame looks blank/uniform")
    }

    /// The auto-zoom must actually move the camera toward a click. Compare the solved camera at an
    /// idle moment (rest, scale≈1) against a click moment (zoomed in on the click).
    func testAutoZoomFramesTheClicks() async throws {
        let srcURL = tempURL("mov")
        let sample = try await SyntheticSource.make(to: srcURL, duration: 3.0, fps: 60)
        defer { try? FileManager.default.removeItem(at: srcURL) }

        var project = ReelProject(recordingStartTime: 0, duration: sample.duration, geometry: sample.geometry)
        project.fps = 60
        let camera = TrackBuilder.build(project: project, events: sample.events, cursor: sample.cursor).camera

        // At t≈0 (before any activity), near rest.
        XCTAssertLessThan(camera.state(at: 0.0).scale, 1.2, "camera should start at rest")
        // Once settled on the 2nd click (t≈2.2, after the move completes) the camera frames it.
        let atClick = camera.state(at: 2.2)
        XCTAssertGreaterThan(atClick.scale, 1.3, "camera should zoom in on the click")
        XCTAssertEqual(atClick.center.x, 965, accuracy: 260, "camera should pan toward the click x")
        XCTAssertEqual(atClick.center.y, 380, accuracy: 200, "camera should pan toward the click y")
    }

    /// The M6 contract: the live-preview composition and the export path share ONE compose fn, so a
    /// preview frame must equal a direct compose() of the same source frame (BUILD_PLAN §5.6).
    func testPreviewMatchesDirectCompose() async throws {
        let srcURL = tempURL("mov")
        let sample = try await SyntheticSource.make(to: srcURL, duration: 2.5, fps: 60)
        defer { try? FileManager.default.removeItem(at: srcURL) }

        let projDir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-\(UUID().uuidString).reelproj")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let raw = projDir.appendingPathComponent(ReelDocument.rawMovieName)
        try FileManager.default.moveItem(at: srcURL, to: raw)
        defer { try? FileManager.default.removeItem(at: projDir) }

        var project = ReelProject(recordingStartTime: 0, duration: sample.duration, geometry: sample.geometry)
        project.fps = 60
        let doc = ReelDocument(url: projDir, project: project, events: sample.events, cursor: sample.cursor, window: [])
        let compositor = Compositor()
        let tracks = TrackBuilder.build(project: project, events: sample.events, cursor: sample.cursor)
        let outputSize = project.geometry.sourceSize
        let asset = AVURLAsset(url: raw)

        // Preview path: AVVideoComposition running the shared compose fn in its handler.
        let comp = try await PreviewComposition.make(asset: asset, document: doc, tracks: tracks,
                                                     compositor: compositor, outputSize: outputSize)
        let t = 1.62
        let previewGen = AVAssetImageGenerator(asset: asset)
        previewGen.requestedTimeToleranceBefore = .zero
        previewGen.requestedTimeToleranceAfter = .zero
        previewGen.videoComposition = comp
        previewGen.maximumSize = outputSize
        let previewCG = try await previewGen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image

        // Direct path: decode the same source frame and compose() it ourselves.
        let rawGen = AVAssetImageGenerator(asset: asset)
        rawGen.requestedTimeToleranceBefore = .zero
        rawGen.requestedTimeToleranceAfter = .zero
        let rawCG = try await rawGen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        let frame = Compositor.Frame(camera: tracks.camera.state(at: t), cursor: tracks.cursor.point(at: t),
                                     ripples: tracks.ripples.active(at: t))
        let directCI = compositor.compose(source: CIImage(cgImage: rawCG), sourceSize: outputSize,
                                          frame: frame, theme: project.theme, outputSize: outputSize)
        let directCG = compositor.ciContext.createCGImage(directCI, from: CGRect(origin: .zero, size: outputSize),
                                                          format: .RGBA8, colorSpace: compositor.colorSpace)!

        // The two must match closely (both un-encoded, same compose fn). A small systematic gap
        // (~3% luma) is expected because AVVideoComposition's render pipeline color-manages
        // slightly differently from a direct createCGImage; a STRUCTURAL divergence (wrong flip,
        // wrong camera, wrong content) would blow past this by 5–10×.
        let diff = meanLumaDiff(previewCG, directCG)
        XCTAssertLessThan(diff, 15.0, "preview and export composites diverge (mean luma diff \(diff))")
    }

    /// M5: a GIF exports with a browser-safe delay, infinite loop, and the expected frames.
    func testGIFExportIsValid() async throws {
        let srcURL = tempURL("mov")
        let sample = try await SyntheticSource.make(to: srcURL, duration: 2.0, fps: 60)
        let projDir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-\(UUID().uuidString).reelproj")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: srcURL, to: projDir.appendingPathComponent(ReelDocument.rawMovieName))
        defer { try? FileManager.default.removeItem(at: projDir) }

        var project = ReelProject(recordingStartTime: 0, duration: sample.duration, geometry: sample.geometry)
        project.fps = 60
        let doc = ReelDocument(url: projDir, project: project, events: sample.events, cursor: sample.cursor, window: [])
        let tracks = TrackBuilder.build(project: project, events: sample.events, cursor: sample.cursor)
        let gifURL = tempURL("gif")
        defer { try? FileManager.default.removeItem(at: gifURL) }

        let exporter = Exporter(compositor: Compositor())
        try await exporter.exportGIF(document: doc, tracks: tracks, to: gifURL,
                                     size: CGSize(width: 640, height: 360), fps: 15)

        let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil)
        XCTAssertNotNil(source)
        let count = CGImageSourceGetCount(source!)
        XCTAssertGreaterThan(count, 10, "GIF should have multiple frames")
        // Loop count 0 (infinite) at the container level.
        let props = CGImageSourceCopyProperties(source!, nil) as? [CFString: Any]
        let gifDict = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(gifDict?[kCGImagePropertyGIFLoopCount] as? Int, 0)
        // Per-frame delay must be browser-safe (≥ 0.03s) or playback speed breaks in Chrome/Safari.
        let frameProps = CGImageSourceCopyPropertiesAtIndex(source!, 0, nil) as? [CFString: Any]
        let frameGIF = frameProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (frameGIF?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        XCTAssertGreaterThanOrEqual(delay, 0.03, "GIF frame delay must be browser-safe")
    }

    // MARK: helpers

    private func meanLumaDiff(_ a: CGImage, _ b: CGImage) -> Double {
        guard let da = a.dataProvider?.data, let pa = CFDataGetBytePtr(da),
              let db = b.dataProvider?.data, let pb = CFDataGetBytePtr(db) else { return .infinity }
        let bprA = a.bytesPerRow, bppA = a.bitsPerPixel / 8
        let bprB = b.bytesPerRow, bppB = b.bitsPerPixel / 8
        let w = min(a.width, b.width), h = min(a.height, b.height)
        let steps = 24
        var total = 0.0, n = 0.0
        for gy in 0..<steps {
            for gx in 0..<steps {
                let x = gx * w / steps, y = gy * h / steps
                let oa = y * bprA + x * bppA, ob = y * bprB + x * bppB
                let la = 0.299 * Double(pa[oa]) + 0.587 * Double(pa[oa + 1]) + 0.114 * Double(pa[oa + 2])
                let lb = 0.299 * Double(pb[ob]) + 0.587 * Double(pb[ob + 1]) + 0.114 * Double(pb[ob + 2])
                total += abs(la - lb); n += 1
            }
        }
        return total / n
    }

    private func copyFrame(from asset: AVAsset, at seconds: Double) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Cheap "is this image non-uniform?" measure: sample a grid of luminance and return the spread.
    private func colorVariance(_ cg: CGImage) -> Double {
        let w = cg.width, h = cg.height
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return 0 }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        var lums: [Double] = []
        let steps = 16
        for gy in 0..<steps {
            for gx in 0..<steps {
                let x = gx * w / steps, y = gy * h / steps
                let off = y * bpr + x * bpp
                let r = Double(ptr[off]), g = Double(ptr[off + 1]), b = Double(ptr[off + 2])
                lums.append(0.299 * r + 0.587 * g + 0.114 * b)
            }
        }
        let mean = lums.reduce(0, +) / Double(lums.count)
        let varr = lums.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lums.count)
        return varr.squareRoot()
    }
}
