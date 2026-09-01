import AppKit
import AVFoundation
import Combine
import CoreImage
import Foundation

/// Drives the Darkroom editor (IMPLEMENTATION_BRIEF §2.4/§2.5). Holds the editable project state,
/// rebuilds the LIVE preview (via the shared compose fn, so preview == export), and re-exports on
/// demand. The untouched `raw.mov` never changes — re-editing is infinite (§3).
@MainActor
final class EditorModel: ObservableObject {

    // MARK: Edit state (everything undoable lives in EditState)

    struct EditState: Equatable {
        var aspect: AspectPreset
        var trimIn: Double
        var trimOut: Double
        var motionDial: Double
        var cursorScale: Double
        var cursorSmoothing: Double
        var clickRipples: Bool
        var paddingFraction: Double
        var cornerRadius: Double
        var shadowLevel: Int              // 0 S · 1 M · 2 L
        var background: BackgroundStyle
        var removeSilence: Bool
        var captionsEnabled: Bool
        var overrides: [CameraOverride]
        var title: String?
    }

    @Published var state: EditState {
        didSet { if state != oldValue { scheduleRefresh() } }
    }
    @Published private(set) var zoomSegments: [ZoomSegment] = []
    @Published var selectedSegmentID: String?

    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []

    // MARK: Playback / preview

    @Published private(set) var player = AVPlayer()
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var filmstrip: [CGImage] = []
    @Published private(set) var silenceCutsPreview: [ClosedRange<Double>] = []
    @Published private(set) var isTranscribing = false
    @Published private(set) var captionError: String?

    // MARK: Export (Darkroom §2.5 sheet)

    enum ExportFormat: String, CaseIterable { case mp4 = "MP4", gif = "GIF", prores = "ProRes" }
    enum ExportResolution: String, CaseIterable { case r1080 = "1080p", r1440 = "1440p", r4k = "4K" }
    @Published var exportFormat: ExportFormat = .mp4
    @Published var exportResolution: ExportResolution = .r1440
    @Published var exportFPS: Int = 60
    @Published var showExportSheet = false
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportedURL: URL?
    @Published var errorText: String?

    private(set) var doc: ReelDocument
    private let compositor = Compositor()
    private var timeObserver: Any?
    private var refreshTask: Task<Void, Never>?

    init(doc: ReelDocument) {
        self.doc = doc
        let p = doc.project
        let shadowLevel: Int = p.theme.shadow.blurRadius < 24 ? 0 : (p.theme.shadow.blurRadius > 44 ? 2 : 1)
        self.state = EditState(aspect: p.theme.aspect,
                               trimIn: p.trimIn, trimOut: p.effectiveTrimOut,
                               motionDial: p.motionDial ?? 0.5,
                               cursorScale: p.cursorScale ?? 1.4,
                               cursorSmoothing: p.cursorSmoothing ?? 0.75,
                               clickRipples: p.clickRipples ?? true,
                               paddingFraction: p.theme.paddingFraction,
                               cornerRadius: p.theme.cornerRadius,
                               shadowLevel: shadowLevel,
                               background: p.theme.background,
                               removeSilence: p.autoRemoveSilence,
                               captionsEnabled: p.captionsEnabled ?? false,
                               overrides: p.overrides,
                               title: p.title)
        addTimeObserver()
        recomputeSegments()
    }

    func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.pause()
        save()
    }

    var totalDuration: Double { doc.project.duration }
    var editedDuration: Double { max(0, state.trimOut - state.trimIn) }
    var displayTitle: String { state.title ?? doc.url.deletingPathExtension().lastPathComponent }

    var outputAspect: CGFloat {
        let sz = RecordingCoordinator.outputSize(for: editedProject())
        return sz.width > 0 && sz.height > 0 ? sz.width / sz.height : 16.0 / 9.0
    }

    // MARK: Undo (§2.4 — every mutation snapshots)

    /// Call BEFORE a user-initiated mutation of `state`.
    func pushUndo() {
        undoStack.append(state)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    func undo() { guard let s = undoStack.popLast() else { return }; redoStack.append(state); state = s }
    func redo() { guard let s = redoStack.popLast() else { return }; undoStack.append(state); state = s }

    // MARK: Transport

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
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

    func scrub(to t: Double) { if player.rate > 0 { player.pause() }; seek(to: t) }

    func step(_ direction: Int, frames: Int = 1) {
        let dt = Double(frames) / Double(max(1, doc.project.fps))
        if player.rate > 0 { player.pause() }
        seek(to: currentTime + Double(direction) * dt)
    }

    /// Raw filmstrip frames for the clip strip (1 frame / ~5 s, §2.4).
    func loadFilmstrip() async {
        let asset = AVURLAsset(url: doc.rawMovieURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 130)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let dur = totalDuration
        let count = max(8, min(24, Int(dur / 5)))
        var raws: [CGImage] = []
        for i in 0..<count {
            let t = dur * (Double(i) + 0.5) / Double(count)
            if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                raws.append(cg)
            }
        }
        filmstrip = raws
    }

    /// Silence spans for the timeline's hatched CUT columns + the Audio section summary.
    func loadSilencePreview() async {
        guard state.removeSilence else { silenceCutsPreview = []; return }
        let project = editedProject()
        let silence = await AudioSilence.intervals(url: doc.rawMovieURL)
        silenceCutsPreview = IdleCutPlanner.cuts(eventTimes: doc.events.map(\.t),
                                                 duration: project.editedDuration, silence: silence)
    }

    var silenceSavings: Double {
        silenceCutsPreview.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    // MARK: Captions (on-device, cached in captions.json)

    /// Toggle handler: first enable transcribes once (on-device) and caches the lines.
    func setCaptions(enabled: Bool) {
        pushUndo()
        state.captionsEnabled = enabled
        guard enabled, doc.captions.isEmpty, !isTranscribing else { return }
        isTranscribing = true
        captionError = nil
        let url = doc.rawMovieURL
        Task { [weak self] in
            do {
                let words = try await AudioTranscriber.words(from: url)
                let lines = CaptionTrack.group(words: words)
                await MainActor.run {
                    guard let self else { return }
                    self.doc.captions = lines
                    self.isTranscribing = false
                    if lines.isEmpty { self.captionError = "No speech found in this take." }
                    self.save()
                    Task { await self.rebuildPreview() }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isTranscribing = false
                    self.captionError = "Captions need Speech permission — grant it in System Settings."
                    self.state.captionsEnabled = false
                }
            }
        }
    }

    // MARK: Zoom segments (§2.4 zoom track)

    private var solverConfig: SolverConfig { ZoomPlan.config(motionDial: state.motionDial) }

    /// Events clipped to the current trim (the editor timeline is the trimmed timeline).
    private var clippedEvents: [InputEvent] {
        let remap = TimeRemap(trimIn: state.trimIn, trimOut: state.trimOut, cuts: [])
        return doc.events.compactMap { e in
            guard let nt = remap.output(e.t) else { return nil }
            var c = e; c.t = nt; return c
        }
    }

    func recomputeSegments() {
        let auto = ZoomPlan.autoClusters(events: clippedEvents,
                                         sourceSize: doc.project.geometry.sourceSize,
                                         config: solverConfig)
        zoomSegments = ZoomPlan.segments(auto: auto, overrides: state.overrides)
        if let sel = selectedSegmentID, !zoomSegments.contains(where: { $0.id == sel }) {
            selectedSegmentID = nil
        }
    }

    var selectedSegment: ZoomSegment? { zoomSegments.first { $0.id == selectedSegmentID } }

    /// Retime/resize/re-aim a segment → an override (move for auto, rewrite for custom).
    func updateSegment(_ id: String, start: Double? = nil, duration: Double? = nil,
                       center: CGPoint? = nil, scale: Double? = nil) {
        guard let seg = zoomSegments.first(where: { $0.id == id }) else { return }
        var ovs = state.overrides
        if let ci = seg.clusterIndex {
            var ov = ovs.last(where: { $0.action == .move && $0.clusterIndex == ci })
                ?? CameraOverride(action: .move, time: seg.start, clusterIndex: ci)
            ov.time = start ?? seg.start
            ov.duration = duration ?? seg.duration
            ov.centerX = (center ?? seg.center).x
            ov.centerY = (center ?? seg.center).y
            ov.scale = scale ?? seg.scale
            ovs.removeAll { $0.action == .move && $0.clusterIndex == ci }
            ovs.append(ov)
        } else if let uuid = UUID(uuidString: String(id.dropFirst("custom-".count))),
                  let idx = ovs.firstIndex(where: { $0.id == uuid }) {
            ovs[idx].time = start ?? seg.start
            ovs[idx].duration = duration ?? seg.duration
            ovs[idx].centerX = (center ?? seg.center).x
            ovs[idx].centerY = (center ?? seg.center).y
            ovs[idx].scale = scale ?? seg.scale
        }
        state.overrides = ovs
    }

    func deleteSegment(_ id: String) {
        guard let seg = zoomSegments.first(where: { $0.id == id }) else { return }
        pushUndo()
        if let ci = seg.clusterIndex {
            state.overrides.removeAll { $0.clusterIndex == ci && $0.action == .move }
            state.overrides.append(CameraOverride(action: .delete, time: seg.start, clusterIndex: ci))
        } else if let uuid = UUID(uuidString: String(id.dropFirst("custom-".count))) {
            state.overrides.removeAll { $0.id == uuid }
        }
        if selectedSegmentID == id { selectedSegmentID = nil }
    }

    /// Reset a segment's user edits back to the auto solve.
    func resetSegment(_ id: String) {
        guard let seg = zoomSegments.first(where: { $0.id == id }), let ci = seg.clusterIndex else { return }
        pushUndo()
        state.overrides.removeAll { $0.clusterIndex == ci }
    }

    func addSegmentAtPlayhead() {
        pushUndo()
        let src = doc.project.geometry.sourceSize
        let ov = CameraOverride(action: .add, time: max(0, currentTime - 0.1),
                                centerX: src.width / 2, centerY: src.height / 2,
                                scale: 1.8, duration: 1.2)
        state.overrides.append(ov)
        selectedSegmentID = "custom-\(ov.id.uuidString)"
    }

    // MARK: Edits → project

    private func themeFromState() -> Theme {
        var t = doc.project.theme
        t.aspect = state.aspect
        t.paddingFraction = state.paddingFraction
        t.cornerRadius = state.cornerRadius
        t.background = state.background
        // Shadow S/M/L (§2.4 Frame): blur 16/32/56, opacity .25/.35/.45, y 6/10/16.
        let blur: [Double] = [16, 32, 56], op: [Double] = [0.25, 0.35, 0.45], y: [Double] = [6, 10, 16]
        let i = min(2, max(0, state.shadowLevel))
        t.shadow = ShadowStyle(blurRadius: blur[i], offsetY: y[i], opacity: op[i])
        return t
    }

    func editedProject() -> ReelProject {
        var p = doc.project
        p.theme = themeFromState()
        p.trimIn = max(0, min(state.trimIn, state.trimOut))
        p.trimOut = state.trimOut
        p.overrides = state.overrides
        p.autoRemoveSilence = state.removeSilence
        p.title = state.title
        p.motionDial = state.motionDial
        p.cursorScale = state.cursorScale
        p.cursorSmoothing = state.cursorSmoothing
        p.clickRipples = state.clickRipples
        p.captionsEnabled = state.captionsEnabled
        return p
    }

    private func editedDoc() -> ReelDocument {
        ReelDocument(url: doc.url, project: editedProject(),
                     events: doc.events, cursor: doc.cursor, window: doc.window)
    }

    /// Persist the current edits into project.json (called on close + after export).
    func save() {
        try? editedDoc().writeSidecars()
    }

    /// Inline rename (§2.4 toolbar): stores the display title; the folder keeps its name.
    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pushUndo()
        state.title = trimmed
    }

    // MARK: Preview

    /// Preview proxy size (perf): same compose fn, export stays full-res.
    static func previewSize(for full: CGSize) -> CGSize {
        let maxW = 1600.0, maxH = 1040.0
        let scale = min(1, min(maxW / max(full.width, 1), maxH / max(full.height, 1)))
        let w = (full.width * scale / 2).rounded(.down) * 2
        let h = (full.height * scale / 2).rounded(.down) * 2
        return CGSize(width: max(w, 2), height: max(h, 2))
    }

    /// Debounced refresh: recompute segments immediately (cheap), rebuild the preview shortly
    /// after the last change (a slider drag fires dozens of updates per second).
    private func scheduleRefresh() {
        recomputeSegments()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await self?.rebuildPreview()
        }
    }

    func rebuildPreview() async {
        let project = editedProject()
        let outputSize = Self.previewSize(for: RecordingCoordinator.outputSize(for: project))
        let tracks = TrackBuilder.build(project: project, events: doc.events, cursor: doc.cursor,
                                        captions: doc.captions, config: solverConfig)
        let asset = AVURLAsset(url: doc.rawMovieURL)
        do {
            let wasPlaying = player.rate > 0
            let resumeAt = currentTime
            let comp = try await PreviewComposition.make(asset: asset, document: editedDoc(), tracks: tracks,
                                                         compositor: compositor, outputSize: outputSize)
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = comp
            player.replaceCurrentItem(with: item)
            seek(to: resumeAt)
            if wasPlaying { player.play() }
            errorText = nil
        } catch {
            errorText = "Preview failed: \(error.localizedDescription)"
        }
    }

    // MARK: Export (§2.5)

    /// Output pixel size for the chosen resolution chip. The cap applies to the SHORT side so
    /// vertical exports land on the exact platform sizes (9:16 · 1080p ⇒ 1080×1920 — what Reels,
    /// Shorts, TikTok and App Store previews expect), and 16:9 · 1080p ⇒ 1920×1080.
    func exportSize() -> CGSize {
        let full = RecordingCoordinator.outputSize(for: editedProject())
        let cap: Double = exportFormat == .gif ? 1080
            : (exportResolution == .r1080 ? 1080 : (exportResolution == .r1440 ? 1440 : 2160))
        let short = min(full.width, full.height)
        let scale = min(1, cap / max(1, short))
        return CGSize(width: (full.width * scale / 2).rounded(.down) * 2,
                      height: (full.height * scale / 2).rounded(.down) * 2)
    }

    /// Rough size estimate for the configure sheet (bitrate table × edited duration).
    var exportEstimate: String {
        let dur = max(0, editedDuration - silenceSavings)
        let mbps: Double
        switch exportFormat {
        case .mp4:    mbps = exportResolution == .r4k ? 16 : (exportResolution == .r1440 ? 9 : 6)
        case .gif:    mbps = 20
        case .prores: mbps = exportResolution == .r4k ? 180 : (exportResolution == .r1440 ? 90 : 60)
        }
        let mb = dur * mbps / 8
        return mb >= 1000 ? String(format: "≈ %.1f GB", mb / 1000) : "≈ \(Int(mb.rounded())) MB"
    }

    var exportDurationLabel: String {
        let dur = max(0, editedDuration - silenceSavings)
        let s = Int(dur.rounded())
        return String(format: "%d:%02d after cuts", s / 60, s % 60)
    }

    func export() async {
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }
        let project = editedProject()
        var cuts: [ClosedRange<Double>] = []
        if project.autoRemoveSilence {
            let silence = await AudioSilence.intervals(url: doc.rawMovieURL)
            cuts = IdleCutPlanner.cuts(eventTimes: doc.events.map(\.t),
                                       duration: project.editedDuration, silence: silence)
        }
        let tracks = TrackBuilder.build(project: project, events: doc.events, cursor: doc.cursor,
                                        cuts: cuts, captions: doc.captions, config: solverConfig)
        let exporter = Exporter(compositor: compositor)
        let outDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Reel", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let ext = exportFormat == .gif ? "gif" : (exportFormat == .prores ? "mov" : "mp4")
        let out = outDir.appendingPathComponent(displayTitle).appendingPathExtension(ext)
        let onProgress: @MainActor @Sendable (Double) -> Void = { [weak self] p in self?.exportProgress = p }
        do {
            switch exportFormat {
            case .gif:
                try await exporter.exportGIF(document: editedDoc(), tracks: tracks, to: out,
                                             size: exportSize(), progress: onProgress)
            case .mp4:
                try await exporter.exportVideo(document: editedDoc(), tracks: tracks, cuts: cuts, to: out,
                                               settings: .init(outputSize: exportSize(), fps: exportFPS,
                                                               codec: .h264, fileType: .mp4,
                                                               watermark: !AppSettings.isLicensed),
                                               progress: onProgress)
            case .prores:
                try await exporter.exportVideo(document: editedDoc(), tracks: tracks, cuts: cuts, to: out,
                                               settings: .init(outputSize: exportSize(), fps: exportFPS,
                                                               codec: .proRes422, fileType: .mov,
                                                               watermark: !AppSettings.isLicensed),
                                               progress: onProgress)
            }
            exportedURL = out
            save()
        } catch {
            errorText = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Copy the exported file — paste straight into Slack / a DM / a tweet (§2.5 payoff).
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
}
