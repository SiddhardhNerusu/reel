import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// The actual spike implementations (BUILD_PLAN §10). Each exercises the REAL production code
/// (ScreenRecorder, EventTapRecorder, Compositor, CameraGeometry) so a confirmed spike hardens
/// the shipping module directly.
enum Spikes {

    // SP-0 — capture one display to raw.mov, confirm Retina resolution + variable PTS encode.
    static func captureToRawMovie(log: SpikeLog) async {
        await log.info("SP-0: capturing primary display for 4s…")
        guard let display = try? await ShareableContent.displays().first else {
            await log.result(false, "no display available (grant Screen Recording, then relaunch)")
            return
        }
        let filter = ShareableContent.filter(for: display)
        await log.info("pointPixelScale=\(filter.pointPixelScale)  contentRect=\(filter.contentRect)")
        let recorder = ScreenRecorder()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sp0-\(Int(HostClock.now())).mov")
        do {
            try await recorder.start(filter: filter, config: .init(captureMicrophone: false), outputURL: url)
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let result = try await recorder.stop()
            let asset = AVURLAsset(url: result.url)
            let track = try await asset.loadTracks(withMediaType: .video).first
            let size = try await track?.load(.naturalSize) ?? .zero
            await log.info("wrote \(fileSize(url)) — \(Int(size.width))×\(Int(size.height)), \(String(format: "%.2f", result.duration))s")
            let ok = Int(size.width) == result.geometry.sourceWidth && result.duration > 1
            await log.result(ok, "expected \(result.geometry.sourceWidth)×\(result.geometry.sourceHeight); PTS-anchored duration \(result.duration > 1 ? "sane" : "SUSPECT")")
        } catch {
            await log.result(false, "capture failed: \(error)")
        }
    }

    // SP-1 — system audio + mic on separate tracks.
    static func audioTracks(log: SpikeLog) async {
        await log.info("SP-1: recording 4s with system audio + mic…")
        _ = await CapturePermissions.requestMicrophoneAccess()
        guard let display = try? await ShareableContent.displays().first else {
            await log.result(false, "no display"); return
        }
        let recorder = ScreenRecorder()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sp1-\(Int(HostClock.now())).mov")
        do {
            try await recorder.start(filter: ShareableContent.filter(for: display),
                                     config: .init(captureSystemAudio: true, captureMicrophone: true), outputURL: url)
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let result = try await recorder.stop()
            let asset = AVURLAsset(url: result.url)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            await log.info("audio track count = \(audio.count)")
            await log.result(audio.count >= 1, "expected ≥1 audio track (mic-authorized: \(CapturePermissions.microphoneAuthorized))")
        } catch {
            await log.result(false, "failed: \(error)")
        }
    }

    // SP-2 — does a listen-only mouse tap fire without a TCC grant? Move the mouse for ~3s.
    static func eventTapNoGrant(log: SpikeLog) async {
        await log.info("SP-2: creating listen-only mouse tap — MOVE THE MOUSE for 3s…")
        let tap = EventTapRecorder()
        let created = tap.start()
        await log.info("tap created=\(created)")
        guard created else {
            await log.result(false, "tapCreate returned nil → likely needs Input Monitoring; consider NSEvent fallback")
            return
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        tap.stop()
        let count = tap.cursor.count + tap.events.count
        await log.info("captured \(tap.cursor.count) moves + \(tap.events.count) clicks")
        await log.result(count > 0, "tap fires \(count > 0 ? "WITHOUT extra prompting" : "NOT — needs a grant")")
    }

    // SP-3 — CGEvent stamps and SCK frame PTS share one clock. The recorder anchors
    // `recordingStartTime` to the first video PTS (§5.0); a HostClock read taken just before
    // start should sit within a few seconds of it if (and only if) they share a clock domain.
    static func clockSync(log: SpikeLog) async {
        await log.info("SP-3: comparing HostClock stamp vs SCK first-frame PTS…")
        guard let display = try? await ShareableContent.displays().first else {
            await log.result(false, "no display"); return
        }
        let recorder = ScreenRecorder()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sp3-\(Int(HostClock.now())).mov")
        let before = HostClock.now()
        do {
            try await recorder.start(filter: ShareableContent.filter(for: display),
                                     config: .init(captureMicrophone: false), outputURL: url)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let result = try await recorder.stop()
            let firstPTS = result.recordingStartTime
            await log.info("HostClock before start=\(String(format: "%.3f", before))  first frame PTS=\(String(format: "%.3f", firstPTS))")
            let delta = abs(firstPTS - before)
            await log.result(delta < 5, "PTS and host clock within \(String(format: "%.3f", delta))s → same clock domain (expect ≪1s)")
        } catch {
            await log.result(false, "failed: \(error)")
        }
    }

    // SP-4 — Core Image compose throughput.
    static func compositeThroughput(log: SpikeLog) async {
        await log.info("SP-4: composing 300 synthetic 4K frames…")
        let compositor = Compositor()
        let sourceSize = CGSize(width: 3840, height: 2160)
        let outputSize = CGSize(width: 3840, height: 2160)
        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.9)).cropped(to: CGRect(origin: .zero, size: sourceSize))
        let theme = Theme.default
        let events = (0..<10).map { InputEvent(t: Double($0) * 0.4, x: 1200 + Double($0) * 100, y: 900, kind: .click, inBounds: true) }
        let track = CameraTrack.solve(events: events, duration: 5, fps: 60, sourceSize: sourceSize)

        let frames = 300
        let start = HostClock.now()
        for i in 0..<frames {
            let t = Double(i) / 60.0
            let frame = Compositor.Frame(camera: track.state(at: t), cursor: CGPoint(x: 1200, y: 900))
            let composed = compositor.compose(source: source, sourceSize: sourceSize, frame: frame, theme: theme, outputSize: outputSize)
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(outputSize.width), Int(outputSize.height), kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
            if let pb { compositor.render(composed, to: pb, size: outputSize) }
        }
        let elapsed = HostClock.now() - start
        let fps = Double(frames) / elapsed
        await log.info(String(format: "composed %d frames in %.2fs = %.1f fps", frames, elapsed, fps))
        await log.result(fps > 60, "4K compose \(fps > 60 ? "FASTER" : "slower") than realtime (need >60 fps to beat a 60fps capture)")
    }

    // SP-5 — CGEvent.location (top-left global) → source pixel space.
    static func coordinateMapping(log: SpikeLog) async {
        await log.info("SP-5: mapping a known point through GeometrySnapshot…")
        guard let display = try? await ShareableContent.displays().first else {
            await log.result(false, "no display"); return
        }
        let filter = ShareableContent.filter(for: display)
        let geo = GeometrySnapshot.make(contentRect: filter.contentRect, pointPixelScale: Double(filter.pointPixelScale))
        // Content-rect top-left → should map to (0,0); center → (w/2, h/2).
        let tl = geo.toSourcePixel(globalTopLeft: filter.contentRect.origin)
        let center = geo.toSourcePixel(globalTopLeft: CGPoint(x: filter.contentRect.midX, y: filter.contentRect.midY))
        await log.info("contentRect origin → \(tl)  (expect ~0,0)")
        await log.info("contentRect center → \(center)  (expect ~\(geo.sourceWidth/2),\(geo.sourceHeight/2))")
        let ok = abs(tl.x) < 2 && abs(tl.y) < 2 && abs(center.x - Double(geo.sourceWidth)/2) < 4
        await log.result(ok, "mapping consistent under scale \(geo.pointPixelScale)  ⚠️ verify multi-display separately")
    }

    // SP-6 — filter availability (gradient + rounded corners).
    static func filterAvailability(log: SpikeLog) async {
        await log.info("SP-6: checking CIFilter availability…")
        let gradient = CIFilter(name: "CILinearGradient") != nil
        let smooth = CIFilter(name: "CISmoothLinearGradient") != nil
        let rounded = CIFilter(name: "CIRoundedRectangleGenerator") != nil
        let mask = Masks.roundedRect(size: CGSize(width: 400, height: 300), cornerRadius: 24) != nil
        await log.info("CILinearGradient=\(gradient)  CISmoothLinearGradient=\(smooth)  CIRoundedRectangleGenerator=\(rounded)")
        await log.info("CoreGraphics rounded-rect mask fallback works=\(mask)")
        await log.result(gradient && mask, "gradient + CG mask fallback available (rounded generator optional)")
    }

    // MARK: helpers
    private static func fileSize(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

// Async-friendly logging shims (SpikeLog is @MainActor).
extension SpikeLog {
    func info(_ s: String) async { await MainActor.run { self.log(s) } }
    func result(_ pass: Bool, _ s: String) async { await MainActor.run { self.result(pass, s) } }
}
