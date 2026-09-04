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
        var zoomEnabled: Bool
        var manualCuts: [ClosedRange<Double>]      // raw seconds
        var restoredCuts: [ClosedRange<Double>]    // auto-cuts the user clicked away (raw)
        var splits: [Double]                       // blade points (raw)
        var overrides: [CameraOverride]
        var title: String?
    }

    @Published var state: EditState {
        didSet { if state != oldValue { scheduleRefresh() } }
    }
    @Published private(set) var zoomSegments: [ZoomSegment] = []
    @Published var selectedSegmentID: String?
    /// Clip piece (between blade points / cuts) selected on the strip — ⌫ removes it.
    @Published var selectedPieceIndex: Int?
    /// Mark in / mark out (EDITED-timeline seconds) — I / O, then Cut.
    @Published var inPoint: Double?
    @Published var outPoint: Double?

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
                               zoomEnabled: p.zoomEnabled ?? true,
                               manualCuts: p.manualCuts ?? [],
                               restoredCuts: p.restoredCuts ?? [],
                               splits: p.splits ?? [],
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

    // MARK: Edited timeline (trim + cuts) — the preview PLAYS this timeline (§ preview == export)

    /// Auto-cuts (silence ∧ idle) in RAW seconds, minus the ones the user restored.
    var autoCuts: [ClosedRange<Double>] {
        state.removeSilence ? TimeRemap.subtract(silenceCutsPreview, state.restoredCuts) : []
    }
    /// Everything removed from the take, normalized, raw seconds.
    var effectiveCuts: [ClosedRange<Double>] { TimeRemap.normalize(autoCuts + state.manualCuts) }
    var remap: TimeRemap { TimeRemap(trimIn: state.trimIn, trimOut: state.trimOut, cuts: effectiveCuts) }
    var editedDuration: Double { remap.editedDuration }

    func rawTime(fromEdited t: Double) -> Double { remap.rawTime(forOutput: t) }
    func editedTime(fromRaw r: Double) -> Double { remap.nearestOutput(r) }
    /// Where the playhead sits on the RAW strip (skips over cut columns).
    var playheadRaw: Double { rawTime(fromEdited: currentTime) }

    /// Kept raw spans split at blade points — the selectable pieces on the clip strip.
    var pieces: [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in remap.keptRanges {
            var lo = r.lowerBound
            for sp in state.splits.sorted() where sp > lo + 0.05 && sp < r.upperBound - 0.05 {
                out.append(lo...sp); lo = sp
            }
            out.append(lo...r.upperBound)
        }
        return out
    }
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

    private var shuttleRate: Float = 0

    func togglePlay() {
        shuttleRate = 0
        if player.rate != 0 { player.pause() }
        else {
            if currentTime >= editedDuration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    /// J / K / L shuttle (Final Cut / Premiere convention): J reverse, K pause, L forward;
    /// repeating J or L doubles the speed up to 8×.
    func shuttle(_ direction: Int) {
        guard direction != 0 else { player.pause(); shuttleRate = 0; return }
        let sameWay = (direction < 0 && shuttleRate < 0) || (direction > 0 && shuttleRate > 0)
        let magnitude: Float = sameWay ? min(abs(shuttleRate) * 2, 8) : 1
        shuttleRate = Float(direction) * magnitude
        if direction > 0, currentTime >= editedDuration - 0.05 { seek(to: 0) }
        player.rate = shuttleRate
    }

    /// All seeks are in EDITED-timeline seconds (what the player plays).
    func seek(to t: Double) {
        player.seek(to: CMTime(seconds: max(0, min(t, editedDuration)), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(to t: Double) { if player.rate != 0 { player.pause(); shuttleRate = 0 }; seek(to: t) }
    /// Two-finger scroll over the preview / timeline (scrubbing like an NLE jog).
    func scrub(by dt: Double) { scrub(to: currentTime + dt) }
    func goToStart() { scrub(to: 0) }
    func goToEnd() { scrub(to: max(0, editedDuration - 1.0 / Double(max(1, doc.project.fps)))) }

    func step(_ direction: Int, frames: Int = 1) {
        let dt = Double(frames) / Double(max(1, doc.project.fps))
        scrub(to: currentTime + Double(direction) * dt)
    }

    // MARK: Cutting & splicing (I/O → Cut, B blade, ⌫ delete piece)

    func markIn() {
        inPoint = currentTime
        if let o = outPoint, o <= currentTime { outPoint = nil }
    }
    func markOut() {
        outPoint = currentTime
        if let i = inPoint, i >= currentTime { inPoint = nil }
    }
    var canCutMarkedRange: Bool {
        if let i = inPoint, let o = outPoint { return o > i + 0.05 }
        return false
    }
    /// Remove everything between the in and out marks.
    func cutMarkedRange() {
        guard let i = inPoint, let o = outPoint, o > i + 0.05 else { return }
        pushUndo()
        addManualCut(rawTime(fromEdited: i)...rawTime(fromEdited: o))
        inPoint = nil; outPoint = nil
    }
    private func addManualCut(_ r: ClosedRange<Double>) {
        let keepAt = editedTime(fromRaw: r.lowerBound)
        state.manualCuts = TimeRemap.normalize(state.manualCuts + [r])
        selectedPieceIndex = nil
        seek(to: min(keepAt, editedDuration))
    }
    /// Blade: split the clip at the playhead so the two sides become separately deletable.
    func blade() {
        let r = playheadRaw
        guard r > state.trimIn + 0.05, r < state.trimOut - 0.05 else { return }
        guard !state.splits.contains(where: { abs($0 - r) < 0.05 }) else { return }
        pushUndo()
        state.splits = (state.splits + [r]).sorted()
    }
    func deleteSelectedPiece() {
        guard let i = selectedPieceIndex, pieces.indices.contains(i) else { return }
        pushUndo()
        addManualCut(pieces[i])
    }
    /// Click a hatched column to bring that span back.
    func restoreCut(_ c: ClosedRange<Double>) {
        pushUndo()
        if state.manualCuts.contains(where: { $0.lowerBound < c.upperBound && $0.upperBound > c.lowerBound }) {
            state.manualCuts = TimeRemap.subtract(state.manualCuts, [c])
        } else {
            state.restoredCuts = TimeRemap.normalize(state.restoredCuts + [c])
        }
    }
    func clearManualCuts() {
        guard !state.manualCuts.isEmpty || !state.splits.isEmpty else { return }
        pushUndo()
        state.manualCuts = []; state.splits = []; selectedPieceIndex = nil
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
    private var autoCutsLoaded = false

    /// Auto-cuts (silence ∧ idle) in RAW seconds — drawn as hatched columns AND removed from
    /// the preview timeline, so what you see is what exports.
    func loadSilencePreview() async {
        guard state.removeSilence else { return }
        let silence = await AudioSilence.intervals(url: doc.rawMovieURL)
        silenceCutsPreview = IdleCutPlanner.cuts(eventTimes: doc.events.map(\.t),
                                                 duration: totalDuration, silence: silence)
        autoCutsLoaded = true
        await rebuildPreview()
    }

    private func ensureAutoCutsLoaded() async {
        if state.removeSilence, !autoCutsLoaded { await loadSilencePreview() }
    }

    var silenceSavings: Double {
        autoCuts.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
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

    private var solverConfig: SolverConfig {
        ZoomPlan.config(motionDial: state.motionDial, enabled: state.zoomEnabled)
    }

    /// Events on the EDITED timeline (trim + cuts applied).
    private var clippedEvents: [InputEvent] {
        let remap = self.remap
        return doc.events.compactMap { e in
            guard let nt = remap.output(e.t) else { return nil }
            var c = e; c.t = nt; return c
        }
    }

    func recomputeSegments() {
        guard state.zoomEnabled else {
            zoomSegments = []; selectedSegmentID = nil; return
        }
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
        p.zoomEnabled = state.zoomEnabled
        p.manualCuts = state.manualCuts
        p.restoredCuts = state.restoredCuts
        p.splits = state.splits
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

    /// The preview plays the EDITED timeline: an AVMutableComposition of the kept raw spans
    /// (trim minus every cut), so cuts are audible and visible while scrubbing — not export-only.
    /// The video composition's time is then edited time directly.
    func rebuildPreview() async {
        let project = editedProject()
        let outputSize = Self.previewSize(for: RecordingCoordinator.outputSize(for: project))
        let cuts = effectiveCuts
        let tracks = TrackBuilder.build(project: project, events: doc.events, cursor: doc.cursor,
                                        cuts: cuts, captions: doc.captions, config: solverConfig)
        let asset = AVURLAsset(url: doc.rawMovieURL)
        do {
            let wasPlaying = player.rate != 0
            let resumeAt = currentTime
            let composition = AVMutableComposition()
            guard let vSrc = try await asset.loadTracks(withMediaType: .video).first,
                  let vDst = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else {
                errorText = "Preview failed: no video track"; return
            }
            let aSrcs = try await asset.loadTracks(withMediaType: .audio)
            let aDsts = aSrcs.compactMap { _ in
                composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            // Clamp to what the track actually contains: project.duration comes from the recorder's
            // PTS bookkeeping and can exceed the muxed track by a frame, and insertTimeRange
            // throws (silently blank preview) if a range pokes past the end.
            let trackRange = try await vSrc.load(.timeRange)
            let trackEnd = trackRange.end.seconds
            var kept = remap.keptRanges.compactMap { r -> ClosedRange<Double>? in
                let lo = max(r.lowerBound, trackRange.start.seconds), hi = min(r.upperBound, trackEnd)
                return hi - lo > 0.02 ? lo...hi : nil
            }
            // Never build an empty composition (the player would wait forever): fall back to the trim.
            if kept.isEmpty {
                kept = [max(0, min(state.trimIn, trackEnd - 0.1))...max(0.1, min(state.trimOut, trackEnd))]
            }
            var at = CMTime.zero
            for r in kept {
                let range = CMTimeRange(start: CMTime(seconds: r.lowerBound, preferredTimescale: 600),
                                        end: CMTime(seconds: r.upperBound, preferredTimescale: 600))
                try vDst.insertTimeRange(range, of: vSrc, at: at)
                for (i, a) in aSrcs.enumerated() where i < aDsts.count {
                    let aRange = (try? await a.load(.timeRange)) ?? range
                    let clipped = CMTimeRangeGetIntersection(range, otherRange: aRange)
                    if clipped.duration.seconds > 0.02 { try? aDsts[i].insertTimeRange(clipped, of: a, at: at) }
                }
                at = at + range.duration
            }
            vDst.preferredTransform = try await vSrc.load(.preferredTransform)

            // A player item built from a MUTABLE composition renders one frame but won't play
            // reliably — hand the item AND the video composition the same immutable snapshot.
            guard let immutable = composition.copy() as? AVComposition else {
                errorText = "Preview failed: composition copy"; return
            }
            let comp = try await PreviewComposition.make(asset: immutable, document: editedDoc(), tracks: tracks,
                                                         compositor: compositor, outputSize: outputSize,
                                                         editedTimeline: true)
            let item = AVPlayerItem(asset: immutable)
            item.videoComposition = comp
            player.replaceCurrentItem(with: item)
            seek(to: resumeAt)
            if wasPlaying { player.rate = shuttleRate == 0 ? 1 : shuttleRate }
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
        let dur = editedDuration
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
        let dur = editedDuration
        let s = Int(dur.rounded())
        return String(format: "%d:%02d after cuts", s / 60, s % 60)
    }

    func export() async {
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }
        let project = editedProject()
        await ensureAutoCutsLoaded()
        let cuts = effectiveCuts      // identical to what the preview is playing
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
