import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stage-2 export (BUILD_PLAN §5.5): decode `raw.mov` → compose each frame through the shared
/// `Compositor` → encode MP4/MOV (or GIF). Runs offline / faster-than-realtime.
final class Exporter {

    struct Settings {
        var outputSize: CGSize
        var fps: Int = 60
        var codec: AVVideoCodecType = .h264
        var fileType: AVFileType = .mp4
        /// Trial watermark chip (unlicensed builds — brief §2.5: the watermark IS the trial).
        var watermark = false
    }

    enum ExportError: Error { case noVideoTrack, cannotCreateReader, cannotCreateWriter, cannotStart }

    private let compositor: Compositor
    init(compositor: Compositor) { self.compositor = compositor }

    /// Render a document to a video file. `progress` (0…1) is delivered on the MainActor in order.
    /// `cuts` are raw video-timeline spans to auto-remove (empty ⇒ trim only).
    func exportVideo(document: ReelDocument,
                     tracks: RenderTracks,
                     cuts: [ClosedRange<Double>] = [],
                     to outputURL: URL,
                     settings: Settings,
                     progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {
        let camera = tracks.camera
        let cursor = tracks.cursor
        let ripples = tracks.ripples
        let project = document.project
        let sourceSize = project.geometry.sourceSize
        let remap = TimeRemap(trimIn: project.trimIn, trimOut: project.effectiveTrimOut, cuts: cuts)
        let editedDuration = remap.editedDuration

        let asset = AVURLAsset(url: document.rawMovieURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // Reader ----------------------------------------------------------
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw ExportError.cannotCreateReader }
        reader.add(videoOut)

        // Audio shares the reader but MUST be pulled interleaved with video (see appendAudio
        // below) — draining one output to EOF before touching the other loses the audio. The mix
        // output folds system audio + mic (two source tracks) into one LPCM stream.
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            if reader.canAdd(out) { reader.add(out); audioOut = out }
        }

        // Writer ----------------------------------------------------------
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.fileType)
        let w = Int(settings.outputSize.width), h = Int(settings.outputSize.height)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw ExportError.cannotCreateWriter }
        writer.add(videoIn)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])

        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            // The mix output decodes to LPCM, so re-encode: AAC is what MP4/MOV expect.
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioIn = input }
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.cannotStart }
        guard writer.startWriting() else { throw writer.error ?? ExportError.cannotStart }
        writer.startSession(atSourceTime: .zero)

        // Feed the writer through requestMediaDataWhenReady, one serial queue per input. With
        // multiple inputs this is the ONLY supported pattern: the writer re-arms an input's
        // isReadyForMoreMediaData exclusively via these callbacks (it interleaves inputs
        // internally), so any polling scheme — sequential passes or manual interleaving —
        // deadlocks with readiness stuck false while the writer waits for the other track.
        let compositor = self.compositor
        let outputSize = settings.outputSize
        let pool: CVPixelBufferPool? = adaptor.pixelBufferPool
        let videoQueue = DispatchQueue(label: "com.neeklabs.reel.export.video")
        let audioQueue = DispatchQueue(label: "com.neeklabs.reel.export.audio")
        let group = DispatchGroup()

        group.enter()
        var videoFinished = false   // touched only on videoQueue
        videoIn.requestMediaDataWhenReady(on: videoQueue) {
            guard !videoFinished else { return }
            func finishVideo() {
                videoFinished = true
                videoIn.markAsFinished()
                group.leave()
            }
            while videoIn.isReadyForMoreMediaData {
                guard let sample = videoOut.copyNextSampleBuffer() else { finishVideo(); return }
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let srcT = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard let t = remap.output(srcT) else {       // trimmed away or inside a cut
                    if srcT > remap.trimOut { finishVideo(); return }
                    continue
                }

                let src = CIImage(cvImageBuffer: imageBuffer)
                let cam = camera.state(at: t)
                let frame = Compositor.Frame(camera: cam, cursor: cursor.point(at: t),
                                             ripples: ripples.active(at: t),
                                             cursorScale: tracks.cursorScale,
                                             caption: tracks.captions.line(at: t),
                                             watermark: settings.watermark)
                let composed = compositor.compose(source: src, sourceSize: sourceSize,
                                                  frame: frame, theme: project.theme, outputSize: outputSize)

                var pb: CVPixelBuffer?
                if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
                guard let outBuffer = pb else { continue }
                compositor.render(composed, to: outBuffer, size: outputSize)
                adaptor.append(outBuffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
                if editedDuration > 0 {
                    let p = min(1, t / editedDuration)
                    Task { @MainActor in progress?(p) }
                }
            }
        }

        if let audioOut, let audioIn {
            group.enter()
            var audioFinished = false   // touched only on audioQueue
            audioIn.requestMediaDataWhenReady(on: audioQueue) {
                guard !audioFinished else { return }
                func finishAudio() {
                    audioFinished = true
                    audioIn.markAsFinished()
                    group.leave()
                }
                while audioIn.isReadyForMoreMediaData {
                    guard let sample = audioOut.copyNextSampleBuffer() else { finishAudio(); return }
                    let srcT = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard let t = remap.output(srcT) else {
                        if srcT > remap.trimOut { finishAudio(); return }
                        continue                              // trimmed away or inside a cut
                    }
                    guard let retimed = Self.retime(sample, by: t - srcT) else { continue }
                    audioIn.append(retimed)
                }
            }
        }

        // Wait for both feeders; poll writer health so a failed writer surfaces as an error
        // instead of an infinite wait (a failed writer stops calling the callbacks).
        while group.wait(timeout: .now() + 1) == .timedOut {
            if writer.status == .failed || reader.status == .failed {
                writer.cancelWriting(); reader.cancelReading()
                try? FileManager.default.removeItem(at: outputURL)
                throw writer.error ?? reader.error ?? ExportError.cannotStart
            }
        }
        // A reader failure ends the loops early; don't finalize a truncated file as "success".
        if reader.status == .failed {
            writer.cancelWriting(); reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            throw reader.error ?? ExportError.cannotStart
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        reader.cancelReading()
        await progress?(1)
        if writer.status == .failed { throw writer.error ?? ExportError.cannotStart }
    }

    // MARK: GIF (§5.5)

    /// Export an animated GIF at a capped fps + size. Browsers clamp very small frame delays, so
    /// we keep delays ≥ 0.03 s rounded to hundredths (§5.5 delay-time trap).
    func exportGIF(document: ReelDocument,
                   tracks: RenderTracks,
                   to outputURL: URL,
                   size: CGSize,
                   fps: Int = 15,
                   progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {
        let camera = tracks.camera
        let cursor = tracks.cursor
        let ripples = tracks.ripples
        let project = document.project
        let sourceSize = project.geometry.sourceSize
        let trimIn = project.trimIn
        let editedDuration = project.editedDuration
        let clampedFps = max(1, min(fps, 33))
        // Quantized delay is the single source of truth: derive BOTH the frame count and each
        // sample time from it so spacing, per-frame delay, and total duration agree (§5.5) —
        // otherwise the GIF plays at the wrong speed.
        let delay = max(0.03, (100.0 / Double(clampedFps)).rounded() / 100.0)  // hundredths, ≥ 0.03
        let frameCount = max(1, Int((editedDuration / delay).rounded()))

        try? FileManager.default.removeItem(at: outputURL)
        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ExportError.cannotCreateWriter
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)

        let asset = AVURLAsset(url: document.rawMovieURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = sourceSize

        let frameProps = [kCGImagePropertyGIFDictionary as String:
            [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary

        for i in 0..<frameCount {
            let t = Double(i) * delay
            let sourceTime = CMTime(seconds: t + trimIn, preferredTimescale: 600)
            // Async image(at:) — copyCGImage(at:actualTime:) is deprecated on macOS 15 (§5.5).
            // A single frame's decode failure must not abort the whole GIF.
            guard let cg = try? await gen.image(at: sourceTime).image else {
                await progress?(Double(i + 1) / Double(frameCount)); continue
            }
            let src = CIImage(cgImage: cg)
            let cam = camera.state(at: t)
            let frame = Compositor.Frame(camera: cam, cursor: cursor.point(at: t),
                                             ripples: ripples.active(at: t),
                                             cursorScale: tracks.cursorScale,
                                             caption: tracks.captions.line(at: t))
            let composed = compositor.compose(source: src, sourceSize: sourceSize,
                                              frame: frame, theme: project.theme, outputSize: size)
            guard let outCG = compositor.ciContext.createCGImage(
                composed, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: compositor.colorSpace)
            else { continue }
            CGImageDestinationAddImage(dest, outCG, frameProps)
            await progress?(Double(i + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.cannotStart }
    }

    // MARK: Helpers

    private static func retime(_ sample: CMSampleBuffer, by offset: Double) -> CMSampleBuffer? {
        guard abs(offset) > 1e-9 else { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: .init(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        let shift = CMTime(seconds: offset, preferredTimescale: 600)
        for i in 0..<timings.count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + shift
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = timings[i].decodeTimeStamp + shift
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
                                              sampleTimingEntryCount: timings.count,
                                              sampleTimingArray: &timings, sampleBufferOut: &out)
        return out
    }
}
