import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Generates a synthetic "recording" — a `raw.mov` plus a matching event/cursor timeline — with NO
/// screen-recording permission required. It fakes a small app UI (a window with a button that gets
/// clicked in three places) so the whole Stage-2 pipeline (solve → compose → export) can be
/// exercised and *seen* offline: it drives the headless render smoke test AND powers the app's
/// "Render sample" button. The frames deliberately contain a bright marker at each click so a test
/// can verify the auto-zoom actually framed the click (coordinate correctness in real pixels).
enum SyntheticSource {

    struct Result {
        var url: URL                    // the generated raw.mov
        var events: [InputEvent]
        var cursor: [CursorSample]
        var geometry: GeometrySnapshot
        var duration: Double
    }

    struct Click { var t: Double; var center: CGPoint }   // source pixels, top-left

    static func make(to url: URL,
                     size: CGSize = CGSize(width: 1280, height: 720),
                     duration: Double = 3.2,
                     fps: Int = 60) async throws -> Result {
        let clicks = [
            Click(t: 0.6, center: CGPoint(x: 330, y: 210)),
            Click(t: 1.6, center: CGPoint(x: 965, y: 380)),
            Click(t: 2.5, center: CGPoint(x: 540, y: 560)),
        ]

        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Writer (raw source: no cursor drawn — the compositor adds the synthetic cursor later).
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let ci = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let frameCount = Int(duration * Double(fps))

        for i in 0..<frameCount {
            let t = Double(i) / Double(fps)
            let cg = drawFrame(t: t, size: size, clicks: clicks)
            let image = CIImage(cgImage: cg)
            var pb: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            }
            guard let buffer = pb else { continue }
            ci.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
            while !input.isReadyForMoreMediaData { usleep(500) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }

        // Event timeline (source px, top-left, already on the video timeline). We know each click's
        // button rect, so we attach it as `targetRect` — exactly what the Accessibility hit-test
        // will provide for real recordings — so the camera frames the button, sized to it.
        let events = clicks.map { c -> InputEvent in
            let btn = CGRect(x: c.center.x - 90, y: c.center.y - 30, width: 180, height: 60)
            return InputEvent(t: c.t, x: c.center.x, y: c.center.y, kind: .click, inBounds: true, targetRect: btn)
        }
        let cursor = cursorPath(clicks: clicks, size: size, duration: duration)
        let geometry = GeometrySnapshot.make(contentRect: CGRect(origin: .zero, size: size), pointPixelScale: 1)
        return Result(url: url, events: events, cursor: cursor, geometry: geometry, duration: duration)
    }

    /// The bright click-marker color, exposed so a test can look for it in the output.
    static let markerRGB = (r: 1.0, g: 0.32, b: 0.20)

    // MARK: Frame drawing

    private static func drawFrame(t: Double, size: CGSize, clicks: [Click]) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CoreGraphics is y-up; draw in a flipped (top-left) space to match our source convention.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        // Background.
        ctx.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))

        // "App window" panel.
        let panel = CGRect(x: 120, y: 70, width: size.width - 240, height: size.height - 140)
        roundRect(ctx, panel, radius: 18, color: CGColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))
        // A faux toolbar + content lines so there's structure to frame.
        roundRect(ctx, CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: 46), radius: 18,
                  color: CGColor(red: 0.90, green: 0.91, blue: 0.94, alpha: 1))
        for row in 0..<6 {
            let y = panel.minY + 90 + CGFloat(row) * 62
            roundRect(ctx, CGRect(x: panel.minX + 40, y: y, width: panel.width - 80, height: 30), radius: 8,
                      color: CGColor(red: 0.88, green: 0.89, blue: 0.92, alpha: 1))
        }

        // The clickable "button": near each click time it lights up with the marker color.
        let active = clicks.min(by: { abs($0.t - t) < abs($1.t - t) })!
        let pressed = abs(active.t - t) < 0.16
        let btn = CGRect(x: active.center.x - 90, y: active.center.y - 30, width: 180, height: 60)
        let base = CGColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 1)
        let hot = CGColor(red: markerRGB.r, green: markerRGB.g, blue: markerRGB.b, alpha: 1)
        roundRect(ctx, btn, radius: 12, color: pressed ? hot : base)

        return ctx.makeImage()!
    }

    private static func roundRect(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, color: CGColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
    }

    // MARK: Cursor path

    private static func cursorPath(clicks: [Click], size: CGSize, duration: Double) -> [CursorSample] {
        // Waypoints: start centered, glide to each click in turn.
        var waypoints: [(t: Double, p: CGPoint)] = [(0, CGPoint(x: size.width / 2, y: size.height / 2))]
        for c in clicks { waypoints.append((c.t, c.center)) }
        waypoints.append((duration, clicks.last?.center ?? CGPoint(x: size.width / 2, y: size.height / 2)))

        var samples: [CursorSample] = []
        let hz = 30.0
        let count = Int(duration * hz)
        for i in 0...count {
            let t = Double(i) / hz
            // Find bracketing waypoints and ease between them.
            var a = waypoints[0], b = waypoints[waypoints.count - 1]
            for j in 0..<(waypoints.count - 1) where t >= waypoints[j].t && t <= waypoints[j + 1].t {
                a = waypoints[j]; b = waypoints[j + 1]; break
            }
            let span = max(1e-3, b.t - a.t)
            let f = smoothstep(min(1, max(0, (t - a.t) / span)))
            let p = CGPoint(x: a.p.x + (b.p.x - a.p.x) * f, y: a.p.y + (b.p.y - a.p.y) * f)
            samples.append(CursorSample(t: t, x: p.x, y: p.y))
        }
        return samples
    }

    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
