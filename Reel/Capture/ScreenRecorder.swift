import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Stage-1 capture spine (BUILD_PLAN §5.0 / §5.1): SCStream → AVAssetWriter, writing an untouched
/// `raw.mov` (video + system audio + mic). Zoom is NEVER baked in here — that is Stage 2.
///
/// Threading (§5.0): each SCK output type lands on its own serial queue and appends ONLY to its
/// own writer input. The writer's session is started once, on the first video sample.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    struct Config {
        var fpsCap: Int = 60
        var captureSystemAudio: Bool = true
        var captureMicrophone: Bool = true
        var codec: AVVideoCodecType = .h264
    }

    struct Result {
        var url: URL
        /// First video PTS in seconds — the §6 `recordingStartTime` anchor.
        var recordingStartTime: Double
        var duration: Double
        var geometry: GeometrySnapshot
        /// Paused spans in raw host-clock seconds — the coordinator removes these from the event
        /// timeline so clicks stay aligned with the (gap-free) recorded video.
        var pausedIntervals: [ClosedRange<Double>]
    }

    enum RecorderError: Error { case alreadyRunning, notRunning, noVideoSettings, noVideoFrames, stoppedWithError }

    // Queues — one owner per resource (§5.0).
    private let videoQueue = DispatchQueue(label: "com.neeklabs.reel.capture.video")
    private let sysAudioQueue = DispatchQueue(label: "com.neeklabs.reel.capture.audioSys")
    private let micQueue = DispatchQueue(label: "com.neeklabs.reel.capture.mic")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sysAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    // Session state — guarded because audio queues read it before appending (§5.0).
    private let sessionLock = NSLock()
    private var startedSession = false
    private var firstPTS: CMTime = .zero
    private var lastPTS: CMTime = .zero

    // Pause/resume (SCStream has no native pause): keep the stream running, drop buffers while
    // paused, and subtract the accumulated paused duration from every buffer's PTS so the recorded
    // timeline has no gap. The SAME offset is applied to all tracks or audio drifts.
    private var isPaused = false
    private var pausedTotal = CMTime.zero          // total time spent paused so far
    private var pauseStartPTS = CMTime.invalid     // last-seen PTS when we paused (stream clock, not wall-clock)
    private var pausedIntervals: [ClosedRange<Double>] = []  // raw host-clock seconds
    /// Video-timeline seconds spent paused — the coordinator uses this to keep events in sync.
    var pausedSeconds: Double { CMTimeGetSeconds(pausedTotal) }

    // Finalization must happen exactly once — stop() and didStopWithError can both reach it and a
    // double markAsFinished()/finishWriting() crashes.
    private let finalizeLock = NSLock()
    private var didFinalize = false

    private var outputURL: URL?
    private var geometry: GeometrySnapshot?
    private var onStop: ((Error?) -> Void)?

    private func claimFinalize() -> Bool {
        finalizeLock.lock(); defer { finalizeLock.unlock() }
        if didFinalize { return false }
        didFinalize = true
        return true
    }

    var isRecording: Bool { stream != nil }

    // MARK: Start

    func start(filter: SCContentFilter, config: Config, outputURL: URL) async throws {
        guard stream == nil else { throw RecorderError.alreadyRunning }

        // Geometry snapshot (§5.2) — pixel size = points × pointPixelScale (Retina).
        let scale = Double(filter.pointPixelScale)
        let geo = GeometrySnapshot.make(contentRect: filter.contentRect, pointPixelScale: scale)
        self.geometry = geo
        self.outputURL = outputURL
        didFinalize = false
        isPaused = false
        pausedTotal = .zero
        pauseStartPTS = .invalid
        pausedIntervals = []
        // Enforce the invariant at the point of use: AVAssetWriter does NOT create missing parent
        // directories, so ensure the enclosing folder (e.g. the .reelproj package) exists.
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)

        // Stream configuration (§5.1).
        let sc = SCStreamConfiguration()
        sc.width = geo.sourceWidth
        sc.height = geo.sourceHeight
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fpsCap))
        sc.queueDepth = 6
        sc.showsCursor = false                       // we draw our own smooth cursor
        sc.capturesAudio = config.captureSystemAudio
        sc.excludesCurrentProcessAudio = true
        sc.sampleRate = 48_000
        sc.channelCount = 2
        sc.captureMicrophone = config.captureMicrophone

        // Writer + inputs — all added before startWriting (§5.0).
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        // Crash-safety for unlimited-length takes: flush a movie fragment every ~2s so a crash/kill
        // leaves a playable file up to the last fragment (research: movieFragmentInterval is the
        // actual crash-safety mechanism — must be set BEFORE startWriting).
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let bitrate = Self.videoBitrate(width: geo.sourceWidth, height: geo.sourceHeight, fps: config.fpsCap)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: config.codec,
            AVVideoWidthKey: geo.sourceWidth,
            AVVideoHeightKey: geo.sourceHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.noVideoSettings }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        var sysAudioInput: AVAssetWriterInput?
        if config.captureSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); sysAudioInput = input }
        }
        var micInput: AVAssetWriterInput?
        if config.captureMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); micInput = input }
        }

        self.writer = writer
        self.videoInput = videoInput
        self.sysAudioInput = sysAudioInput
        self.micInput = micInput
        startedSession = false

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.noVideoSettings
        }

        // Wire outputs — each type on its own serial queue (§5.0).
        let stream = SCStream(filter: filter, configuration: sc, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if config.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysAudioQueue)
        }
        if config.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    // MARK: Stop

    /// Stops capture and finalizes the writer. ALWAYS finalizes (§5.0) so `raw.mov` stays playable.
    func stop() async throws -> Result {
        guard let stream, let writer, let geometry, let outputURL else {
            throw RecorderError.notRunning
        }
        try? await stream.stopCapture()
        self.stream = nil

        // If the stream already errored out, didStopWithError finalized the writer — don't do it
        // again (double finishWriting crashes).
        guard claimFinalize() else {
            cleanup()
            throw RecorderError.stoppedWithError
        }

        videoInput?.markAsFinished()
        sysAudioInput?.markAsFinished()
        micInput?.markAsFinished()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }

        let (hasVideo, start, duration): (Bool, Double, Double) = sessionLock.withLock {
            let s = CMTimeGetSeconds(firstPTS)
            // Duration excludes paused time (frames were retimed to remove the gaps).
            return (startedSession, s, max(0, CMTimeGetSeconds(lastPTS) - s - CMTimeGetSeconds(pausedTotal)))
        }

        // No video frame ever arrived ⇒ the file has an unstarted session and every event would
        // keep an un-normalized (absolute) timestamp. Treat as a failed recording.
        guard hasVideo, writer.status != .failed else {
            try? FileManager.default.removeItem(at: outputURL)
            let err = writer.error
            cleanup()
            throw err ?? RecorderError.noVideoFrames
        }

        cleanup()
        return Result(url: outputURL, recordingStartTime: start, duration: duration,
                      geometry: geometry, pausedIntervals: pausedIntervals)
    }

    private func cleanup() {
        writer = nil
        videoInput = nil
        sysAudioInput = nil
        micInput = nil
        outputURL = nil
        geometry = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            appendAudio(sampleBuffer, to: sysAudioInput)
        case .microphone:
            appendAudio(sampleBuffer, to: micInput)
        @unknown default:
            break
        }
    }

    // MARK: Pause / Resume

    func pause() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard !isPaused, startedSession else { return }
        isPaused = true
        pauseStartPTS = lastPTS          // latch from the stream clock, not wall-clock
    }

    func resume() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard isPaused else { return }
        if pauseStartPTS.isValid {
            pausedTotal = pausedTotal + (lastPTS - pauseStartPTS)
            let a = CMTimeGetSeconds(pauseStartPTS), b = CMTimeGetSeconds(lastPTS)
            if b > a { pausedIntervals.append(a...b) }
        }
        isPaused = false
        pauseStartPTS = .invalid
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        // Only append COMPLETE frames — .screen buffers can be idle/blank/suspended status-only.
        guard sampleBuffer.imageBuffer != nil, Self.isCompleteFrame(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        sessionLock.lock()
        lastPTS = pts                     // track the stream clock even while paused (for pause math)
        let paused = isPaused
        let offset = pausedTotal
        if !startedSession && !paused {
            writer?.startSession(atSourceTime: pts)   // §5.0 step 2 — anchor once at first real frame
            firstPTS = pts
            startedSession = true
        }
        sessionLock.unlock()

        if paused { return }              // drop frames captured while paused (no gap in the file)
        guard let input = videoInput, input.isReadyForMoreMediaData else { return }  // drop, never block
        if let out = Self.retimed(sampleBuffer, by: offset) { input.append(out) }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        sessionLock.lock()
        let ready = startedSession, paused = isPaused, offset = pausedTotal
        sessionLock.unlock()
        guard ready, !paused, let input, input.isReadyForMoreMediaData else { return }
        if let out = Self.retimed(sampleBuffer, by: offset) { input.append(out) }
    }

    /// Whether an SCK screen sample buffer carries a complete (drawable) frame.
    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first, let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return true }   // unknown ⇒ don't drop
        return status == .complete
    }

    /// Copy a sample buffer with every timestamp shifted back by `offset` (removes paused gaps).
    private static func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset.isValid, offset != .zero else { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: .init(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid { timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - offset }
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb,
                                              sampleTimingEntryCount: timings.count,
                                              sampleTimingArray: &timings, sampleBufferOut: &out)
        return out
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Mid-record failure — finalize so the partial file is still playable (§5.1 policy), but
        // only if stop() hasn't already claimed finalization (double finishWriting crashes).
        self.stream = nil
        guard claimFinalize() else { onStop?(error); return }
        videoInput?.markAsFinished()
        sysAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        writer?.finishWriting { [onStop] in onStop?(error) }
    }

    /// Optional hook for the coordinator to learn about async stop-with-error.
    func setStopHandler(_ handler: @escaping (Error?) -> Void) { onStop = handler }

    // MARK: Helpers

    private static func videoBitrate(width: Int, height: Int, fps: Int) -> Int {
        // ~0.15 bits/pixel/frame, capped — raw capture wants high quality, not tiny files.
        let bits = Double(width * height) * Double(fps) * 0.15
        return min(60_000_000, max(6_000_000, Int(bits)))
    }
}
