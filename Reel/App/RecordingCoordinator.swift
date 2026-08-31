import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit

/// Orchestrates a full record → project → export round-trip (BUILD_PLAN §3). Owns the recorder
/// and event tap; normalizes the timelines into a `.reelproj`; drives the solver + exporter.
/// MainActor — the UI observes it; the heavy work hops to background tasks.
@MainActor
final class RecordingCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case needsPermission
        case recording
        case processing(String)
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastProject: ReelDocument?
    @Published var exportProgress: Double = 0
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var isPaused = false
    private var pausedAt: Date?
    /// Drives the permission gate. Set by actually ATTEMPTING to enumerate shareable content —
    /// which both tests access AND registers the app in the Screen Recording list (a preflight
    /// check alone does neither). nil = not checked yet.
    @Published private(set) var hasAccess: Bool = false

    private let recorder = ScreenRecorder()
    private let events = EventTapRecorder()
    private let compositor = Compositor()

    private var recordingURL: URL?
    private var currentGeometry: GeometrySnapshot?

    var hasScreenAccess: Bool { CapturePermissions.hasScreenRecordingAccess }

    /// Attempt to enumerate shareable content. Success ⇒ we have access. Failure ⇒ we don't, but
    /// the attempt registers Reel in System Settings ▸ Screen Recording so the user can enable it.
    /// This is the source of truth for the permission gate (more reliable than `CGPreflight…`).
    func checkAccess() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            hasAccess = true
        } catch {
            hasAccess = false
        }
        // Ask for Accessibility here (launcher appear), not at record-start — the system dialog
        // must never end up inside a take. Recording works without the grant; zoom just falls
        // back to a padded click-point box instead of the clicked element's rect.
        if !ElementResolver.isTrusted { ElementResolver.requestTrust() }
    }

    // MARK: Record

    func startRecording(display: SCDisplay, excluding ownWindows: [SCWindow] = []) async {
        guard CapturePermissions.requestScreenRecordingAccess() else {
            phase = .needsPermission
            return
        }
        _ = await CapturePermissions.requestMicrophoneAccess()

        // Keep Reel's own chrome (launcher, recording pill) out of the take. Callers may pass a
        // specific list; otherwise resolve every window owned by this process.
        var exclude = ownWindows
        if exclude.isEmpty,
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
            let bundleID = Bundle.main.bundleIdentifier
            exclude = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
        }
        let filter = ShareableContent.filter(for: display, excluding: exclude)
        let url = Self.newProjectURL()
        // The .reelproj package must exist before AVAssetWriter opens raw.mov inside it (the writer
        // does not create parent directories).
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            // Smarter zoom targeting: resolve the clicked element per click if Accessibility is
            // granted (falls back to a padded box around the point otherwise).
            events.resolvesElements = ElementResolver.isTrusted
            events.start()  // start the tap slightly before capture; we align by host clock anyway
            recorder.setStopHandler { [weak self] error in
                Task { @MainActor in self?.handleStreamStopped(error) }
            }
            try await recorder.start(filter: filter, config: .init(), outputURL: url.appendingPathComponent(ReelDocument.rawMovieName))
            recordingURL = url
            currentGeometry = GeometrySnapshot.make(contentRect: filter.contentRect,
                                                    pointPixelScale: Double(filter.pointPixelScale))
            recordingStartedAt = Date()
            phase = .recording
        } catch {
            events.stop()
            try? FileManager.default.removeItem(at: url)
            phase = .failed("Couldn’t start recording: \(error.localizedDescription)")
        }
    }

    /// The capture stream stopped on its own (mid-record failure, §5.1). Surface it and stop the
    /// event tap; the partial `raw.mov` was finalized by the recorder so it stays playable.
    private func handleStreamStopped(_ error: Error?) {
        guard case .recording = phase else { return }   // normal stop() path handles itself
        events.stop()
        recordingStartedAt = nil
        if let error {
            phase = .failed("Recording stopped: \(error.localizedDescription)")
        } else {
            phase = .idle
        }
    }

    /// Pause/resume the in-progress recording (frames + audio are dropped while paused; the file
    /// has no gap). Events during the pause are removed from the timeline at finalize.
    func togglePause() {
        guard case .recording = phase else { return }
        if isPaused {
            recorder.resume()
            // Shift the elapsed-time anchor forward by however long we were paused.
            if let pausedAt = pausedAt { recordingStartedAt = recordingStartedAt?.addingTimeInterval(Date().timeIntervalSince(pausedAt)) }
            pausedAt = nil
            isPaused = false
        } else {
            recorder.pause()
            pausedAt = Date()
            isPaused = true
        }
    }

    func stopRecording() async {
        guard case .recording = phase else { return }
        phase = .processing("Finalizing recording…")
        events.stop()
        recordingStartedAt = nil
        isPaused = false
        pausedAt = nil
        do {
            let result = try await recorder.stop()
            let doc = try buildDocument(from: result)
            lastProject = doc
            phase = .idle
        } catch {
            phase = .failed("Couldn’t finalize: \(error.localizedDescription)")
        }
    }

    /// Generate a synthetic demo (a fake app UI being clicked) and export it — NO screen-recording
    /// permission required. Lets you see the auto-zoom / background / cursor immediately, and is a
    /// great landing-page/portfolio piece to render with the app itself.
    func renderSampleDemo() async {
        phase = .processing("Generating sample…")
        let projDir = Self.newProjectURL()
        do {
            try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
            let raw = projDir.appendingPathComponent(ReelDocument.rawMovieName)
            let sample = try await SyntheticSource.make(to: raw)
            var project = ReelProject(recordingStartTime: 0, duration: sample.duration, geometry: sample.geometry)
            project.fps = 60
            let doc = ReelDocument(url: projDir, project: project,
                                   events: sample.events, cursor: sample.cursor, window: [])
            try doc.writeSidecars()
            lastProject = doc
            let out = projDir.deletingPathExtension().appendingPathExtension("mp4")
            await export(doc, to: out)
        } catch {
            phase = .failed("Sample failed: \(error.localizedDescription)")
        }
    }

    /// Convenience for spikes/manual test: record for a fixed duration.
    func recordFixed(display: SCDisplay, seconds: Double) async {
        await startRecording(display: display)
        guard case .recording = phase else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await stopRecording()
    }

    // MARK: Build the .reelproj (normalize timelines → video timeline, map → source px)

    private func buildDocument(from result: ScreenRecorder.Result) throws -> ReelDocument {
        let geo = result.geometry
        let start = result.recordingStartTime

        // Map a raw host-clock time to the video timeline, removing paused spans (so clicks stay
        // aligned with the gap-free recorded video). Returns nil if the event happened during a pause.
        func adjusted(_ t: Double) -> Double? {
            var pausedBefore = 0.0
            for iv in result.pausedIntervals {
                if t >= iv.lowerBound && t <= iv.upperBound { return nil }  // during a pause — drop
                if iv.upperBound < t { pausedBefore += iv.upperBound - iv.lowerBound }
            }
            let nt = (t - start) - pausedBefore
            return nt >= 0 ? nt : nil
        }

        // Events: absolute host t → video-timeline t; global points → source px; flag out-of-bounds;
        // attach the resolved clicked-element rect (→ source px) for size-aware zoom targeting.
        let rects = events.elementRects
        let inputEvents: [InputEvent] = events.events.enumerated().compactMap { i, raw in
            guard let nt = adjusted(raw.t) else { return nil }
            let px = geo.toSourcePixel(globalTopLeft: raw.location)
            let targetRect = rects[i].map { geo.toSourceRect(globalTopLeft: $0) }
            return InputEvent(t: nt, x: px.x, y: px.y, kind: raw.kind,
                              inBounds: geo.contains(sourcePixel: px), targetRect: targetRect)
        }

        let cursor: [CursorSample] = events.cursor.compactMap { raw in
            guard let nt = adjusted(raw.t) else { return nil }
            let px = geo.toSourcePixel(globalTopLeft: raw.location)
            return CursorSample(t: nt, x: px.x, y: px.y)
        }

        var project = ReelProject(recordingStartTime: start, duration: result.duration, geometry: geo)
        project.fps = 60

        let doc = ReelDocument(url: result.url.deletingLastPathComponent(),
                               project: project, events: inputEvents, cursor: cursor, window: [])
        try doc.writeSidecars()
        return doc
    }

    // MARK: Export

    func export(_ doc: ReelDocument, to outputURL: URL, gif: Bool = false) async {
        phase = .processing(gif ? "Rendering GIF…" : "Rendering video…")
        exportProgress = 0
        let outputSize = Self.outputSize(for: doc.project)
        // Auto-remove long silent + idle spans (on-device; no API). Empty for the sample / short gaps.
        var cuts: [ClosedRange<Double>] = []
        if doc.project.autoRemoveSilence {
            let silence = await AudioSilence.intervals(url: doc.rawMovieURL)
            cuts = IdleCutPlanner.cuts(eventTimes: doc.events.map(\.t),
                                       duration: doc.project.editedDuration, silence: silence)
        }
        // Clip + rebase to the current trim window + cuts so camera/cursor/ripples stay in sync.
        let tracks = TrackBuilder.build(project: doc.project, events: doc.events, cursor: doc.cursor, cuts: cuts)
        let exporter = Exporter(compositor: compositor)
        // Ordered MainActor progress (no per-tick Task ⇒ no out-of-order regressions).
        let onProgress: @MainActor @Sendable (Double) -> Void = { [weak self] p in self?.exportProgress = p }
        do {
            if gif {
                try await exporter.exportGIF(document: doc, tracks: tracks,
                                             to: outputURL, size: outputSize, progress: onProgress)
            } else {
                try await exporter.exportVideo(document: doc, tracks: tracks, cuts: cuts,
                                               to: outputURL,
                                               settings: .init(outputSize: outputSize, fps: doc.project.fps),
                                               progress: onProgress)
            }
            phase = .ready(outputURL)
        } catch {
            phase = .failed("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    static func outputSize(for project: ReelProject) -> CGSize {
        let src = project.geometry.sourceSize
        guard let ratio = project.theme.aspect.ratio else { return src }
        // Fit the source inside a canvas of the target ratio at ~source height.
        let h = src.height
        return CGSize(width: (h * ratio).rounded(), height: h.rounded())
    }

    static func newProjectURL() -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = "Reel-\(Int(HostClock.now())).reelproj"
        return dir.appendingPathComponent(name)
    }
}
