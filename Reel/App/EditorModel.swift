import AppKit
import AVFoundation
import Combine
import CoreImage
import Foundation

/// Drives the M6 editor (BUILD_PLAN §11 M6). Holds the editable project state, rebuilds the LIVE
/// preview (via the shared compose fn, so preview == export), and re-exports on demand. Editing a
/// theme/aspect/trim just rebuilds the preview composition — the untouched `raw.mov` never changes,
/// which is what makes re-editing infinite (§3).
@MainActor
final class EditorModel: ObservableObject {

    @Published var presetIndex: Int
    @Published var aspect: AspectPreset
    @Published var trimIn: Double
    @Published var trimOut: Double
    @Published var autoZoom: Bool = true

    @Published private(set) var player = AVPlayer()
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var filmstrip: [CGImage] = []

    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportedURL: URL?
    @Published var errorText: String?

    let doc: ReelDocument
    private let compositor = Compositor()
    private var timeObserver: Any?

    init(doc: ReelDocument) {
        self.doc = doc
        self.presetIndex = ThemePresets.index(matching: doc.project.theme)
        self.aspect = doc.project.theme.aspect
        self.trimIn = doc.project.trimIn
        self.trimOut = doc.project.effectiveTrimOut
        addTimeObserver()
    }

    /// Called from the view's onDisappear — removes the observer before the player deallocates
    /// (removing it from a nonisolated deinit would touch MainActor state, which isn't allowed).
    func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.pause()
    }

    var totalDuration: Double { doc.project.duration }

    /// Current output aspect (w/h) — the preview frame hugs this so there's no black letterbox.
    var outputAspect: CGFloat {
        let sz = RecordingCoordinator.outputSize(for: editedProject())
        return sz.width > 0 && sz.height > 0 ? sz.width / sz.height : 16.0 / 9.0
    }

    // MARK: Transport

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            // Registered on the main queue, so we're genuinely on the MainActor here.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player.rate > 0
            }
        }
    }

    func togglePlay() {
        if player.rate > 0 { player.pause() }
        else {
            if currentTime >= totalDuration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    func seek(to t: Double) {
        player.seek(to: CMTime(seconds: max(0, min(t, totalDuration)), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Pause + seek — used while dragging the playhead so scrubbing doesn't fight playback.
    func scrub(to t: Double) { if player.rate > 0 { player.pause() }; seek(to: t) }

    /// Step one frame (arrow keys).
    func step(_ direction: Int) {
        let dt = 1.0 / Double(max(1, doc.project.fps))
        if player.rate > 0 { player.pause() }
        seek(to: currentTime + Double(direction) * dt)
    }

    /// Sample evenly-spaced RAW frames for the trim filmstrip. A trim strip should show the actual
    /// recording content (so you can see where to cut) — not the styled output.
    func loadFilmstrip(count: Int = 12) async {
        let asset = AVURLAsset(url: doc.rawMovieURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 220, height: 140)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let dur = totalDuration
        var raws: [CGImage] = []
        for i in 0..<count {
            let t = dur * (Double(i) + 0.5) / Double(count)
            if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                raws.append(cg)
            }
        }
        filmstrip = raws
    }

    // MARK: Edits → project / tracks

    private var solverConfig: SolverConfig {
        autoZoom ? .default : SolverConfig(minScale: 1, maxScale: 1)   // off ⇒ camera stays at rest
    }

    private func editedProject() -> ReelProject {
        var p = doc.project
        p.theme = ThemePresets.apply(ThemePresets.all[min(presetIndex, ThemePresets.all.count - 1)], to: p.theme)
        p.theme.aspect = aspect
        p.trimIn = max(0, min(trimIn, trimOut))
        p.trimOut = trimOut
        return p
    }

    private func editedDoc() -> ReelDocument {
        ReelDocument(url: doc.url, project: editedProject(), events: doc.events, cursor: doc.cursor, window: doc.window)
    }

    private func currentTracks(for project: ReelProject) -> RenderTracks {
        TrackBuilder.build(project: project, events: doc.events, cursor: doc.cursor, config: solverConfig)
    }

    // MARK: Preview

    /// Preview proxy size: fit inside ~1.6MP keeping aspect, even dimensions. Compositing the
    /// full source (e.g. 3456×2234 = 7.7MP) through the CI graph 60×/s stutters during zooms,
    /// and the preview view is far smaller anyway. Export still runs at full resolution through
    /// the same compose function.
    static func previewSize(for full: CGSize) -> CGSize {
        let maxW = 1600.0, maxH = 1040.0
        let scale = min(1, min(maxW / max(full.width, 1), maxH / max(full.height, 1)))
        let w = (full.width * scale / 2).rounded(.down) * 2
        let h = (full.height * scale / 2).rounded(.down) * 2
        return CGSize(width: max(w, 2), height: max(h, 2))
    }

    /// Rebuild the live preview from the current edits.
    func rebuildPreview() async {
        let project = editedProject()
        let outputSize = Self.previewSize(for: RecordingCoordinator.outputSize(for: project))
        let tracks = currentTracks(for: project)
        let asset = AVURLAsset(url: doc.rawMovieURL)
        do {
            let comp = try await PreviewComposition.make(asset: asset, document: editedDoc(), tracks: tracks,
                                                         compositor: compositor, outputSize: outputSize)
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = comp
            player.replaceCurrentItem(with: item)
            errorText = nil
        } catch {
            errorText = "Preview failed: \(error.localizedDescription)"
        }
    }

    // MARK: Export

    func export(gif: Bool = false) async {
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }
        let project = editedProject()
        let outputSize = RecordingCoordinator.outputSize(for: project)
        // Auto-remove silent + idle spans on export (on-device). Preview stays uncut for scrubbing.
        var cuts: [ClosedRange<Double>] = []
        if project.autoRemoveSilence {
            let silence = await AudioSilence.intervals(url: doc.rawMovieURL)
            cuts = IdleCutPlanner.cuts(eventTimes: doc.events.map(\.t),
                                       duration: project.editedDuration, silence: silence)
        }
        let tracks = TrackBuilder.build(project: project, events: doc.events, cursor: doc.cursor, cuts: cuts)
        let exporter = Exporter(compositor: compositor)
        let out = doc.url.deletingPathExtension().appendingPathExtension(gif ? "gif" : "mp4")
        let onProgress: @MainActor @Sendable (Double) -> Void = { [weak self] p in self?.exportProgress = p }
        do {
            if gif {
                try await exporter.exportGIF(document: editedDoc(), tracks: tracks, to: out,
                                             size: outputSize, progress: onProgress)
            } else {
                try await exporter.exportVideo(document: editedDoc(), tracks: tracks, cuts: cuts, to: out,
                                               settings: .init(outputSize: outputSize, fps: project.fps),
                                               progress: onProgress)
            }
            exportedURL = out
        } catch {
            errorText = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Put the exported file on the clipboard — paste straight into Slack / a DM / a tweet.
    /// The single most-used action for a demo tool.
    func copyExportToClipboard() {
        guard let url = exportedURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    func revealExport() {
        guard let url = exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func dismissToast() { exportedURL = nil }
}
