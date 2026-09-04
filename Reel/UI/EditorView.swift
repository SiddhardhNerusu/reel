import AVKit
import SwiftUI

/// The Darkroom editor (IMPLEMENTATION_BRIEF §2.4, artboard 1d).
/// toolbar 52 / preview+inspector / timeline 164. The preview is the hero; chrome stays matte.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    var onBack: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var previewFrame: CGRect = .zero
    @State private var timelineFrame: CGRect = .zero
    @State private var scrollMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(RC.hairlineSoft).frame(height: 1)
            HStack(spacing: 0) {
                previewArea
                Rectangle().fill(RC.hairlineSoft).frame(width: 1)
                InspectorView(model: model)
                    .frame(width: 296)
                    .background(RC.base)
            }
            Rectangle().fill(RC.hairlineSoft).frame(height: 1)
            EditorTimeline(model: model)
                .frame(height: 164)
                .background(RC.base)
                .background(GeometryReader { g in
                    Color.clear.onAppear { timelineFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in timelineFrame = f }
                })
        }
        .background(RC.base)
        .frame(minWidth: 1280, minHeight: 800)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .task {
            focused = true
            await model.rebuildPreview()
            await model.loadFilmstrip()
            await model.loadSilencePreview()
        }
        .onAppear { installScrollScrub() }
        .onDisappear { model.teardown(); removeScrollScrub() }
        .sheet(isPresented: $model.showExportSheet) { ExportSheet(model: model) }
        // NLE conventions (Final Cut / Premiere): space, J K L, ← →, ⇧← ⇧→, I O, B, ⌫, Home/End.
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(.deleteForward) { deleteSelected(); return .handled }
        .onKeyPress(.delete) { deleteSelected(); return .handled }
        .onKeyPress(.home) { model.goToStart(); return .handled }
        .onKeyPress(.end) { model.goToEnd(); return .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let frames = press.modifiers.contains(.shift) ? 10 : 1
            model.step(press.key == .leftArrow ? -1 : 1, frames: frames)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "jklJKLioIObB")) { press in
            switch press.characters.lowercased() {
            case "j": model.shuttle(-1)
            case "k": model.shuttle(0)
            case "l": model.shuttle(1)
            case "i": model.markIn()
            case "o": model.markOut()
            case "b": model.blade()
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.escape) { model.inPoint = nil; model.outPoint = nil; model.selectedPieceIndex = nil; return .handled }
    }

    private func deleteSelected() {
        if let id = model.selectedSegmentID { model.deleteSegment(id) }
        else if model.selectedPieceIndex != nil { model.deleteSelectedPiece() }
        else if model.canCutMarkedRange { model.cutMarkedRange() }
    }

    // Two-finger horizontal scroll over the preview or timeline scrubs (jog wheel feel).
    // A local monitor sees the wheel before any view; the frames are SwiftUI global (top-left).
    private func installScrollScrub() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak model] event in
            guard let model, let window = event.window, window.isKeyWindow,
                  let content = window.contentView else { return event }
            let p = event.locationInWindow
            let pt = CGPoint(x: p.x, y: content.bounds.height - p.y)
            let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : 0
            guard abs(dx) > 0.01 else { return event }
            if previewFrame.contains(pt) {
                MainActor.assumeIsolated { model.scrub(by: Double(dx) * 0.02) }   // ~1 s per 50 pt
                return nil
            }
            if timelineFrame.contains(pt) {
                let px = max(1, (timelineFrame.width - 170 - 24) / max(0.1, model.totalDuration))
                MainActor.assumeIsolated { model.scrub(by: Double(dx) / Double(px)) }
                return nil
            }
            return event
        }
    }
    private func removeScrollScrub() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    // MARK: Toolbar (§2.4)

    @State private var renaming = false
    @State private var renameText = ""

    private var toolbar: some View {
        HStack(spacing: 14) {
            Spacer().frame(width: 64)   // traffic lights
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text("Back").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(RC.ink2)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RC.raised, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            if renaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RC.ink)
                    .frame(width: 200)
                    .onSubmit { model.rename(to: renameText); renaming = false }
                    .onExitCommand { renaming = false }
            } else {
                Button {
                    renameText = model.displayTitle; renaming = true
                } label: {
                    HStack(spacing: 4) {
                        Text(model.displayTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(RC.ink)
                        Text(".reel").font(RC.mono(10.5)).foregroundStyle(RC.ink4)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()

            HStack(spacing: 6) {
                ForEach(AspectPreset.allCases, id: \.self) { a in
                    Chip(text: a.label, selected: model.state.aspect == a) {
                        model.pushUndo(); model.state.aspect = a
                    }
                }
            }
            Rectangle().fill(RC.hairlineSoft).frame(width: 1, height: 20)
            HStack(spacing: 2) {
                iconButton("arrow.uturn.backward", enabled: model.canUndo) { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                iconButton("arrow.uturn.forward", enabled: model.canRedo) { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            Button {
                model.showExportSheet = true
            } label: {
                HStack(spacing: 7) {
                    Text("Export")
                    Text("⌘E").font(RC.mono(10.5)).opacity(0.6)
                }
            }
            .buttonStyle(.reelPrimary)
            .keyboardShortcut("e", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(RC.base)
    }

    private func iconButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? RC.ink2 : RC.ink.opacity(0.25))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Preview (§2.4 — the stage)

    private var previewArea: some View {
        GeometryReader { geo in
            let avail = CGSize(width: max(geo.size.width - 72, 40), height: max(geo.size.height - 72, 30))
            let aspect = model.outputAspect
            let w = min(avail.width, avail.height * aspect)
            let h = w / aspect
            ZStack {
                RC.stage
                if let err = model.errorText {
                    Text(err).font(.system(size: 12)).foregroundStyle(RC.live)
                        .padding(10).background(RC.raised, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 12)
                        .zIndex(2)
                }
                ZStack {
                    PlayerLayerView(player: model.player)
                    if model.state.aspect == .r9x16 || model.state.aspect == .r4x5 {
                        SafeAreaGuides()
                    }
                    ZoomTargetOverlay(model: model)
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: RC.rCard))
                .background(GeometryReader { g in
                    Color.clear.onAppear { previewFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in previewFrame = f }
                })
                .overlay(RoundedRectangle(cornerRadius: RC.rCard).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 70, y: 30)
                .shadow(color: .black.opacity(0.30), radius: 14, y: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - AVPlayerLayer host

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: PlayerNSView, context: Context) { v.playerLayer.player = player }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
        }
        required init?(coder: NSCoder) { fatalError("unsupported") }
    }
}

// MARK: - Zoom target box (§2.4 — dashed amber, drag to re-aim, corner handles to re-scale)

/// Drawn over the preview while a zoom block is selected. Maps the segment's camera viewport
/// (source px) into preview coordinates assuming a REST camera — selecting a block scrubs to just
/// before its activation, where the camera is (near) rest, so the box lines up with the footage.
struct ZoomTargetOverlay: View {
    @ObservedObject var model: EditorModel
    @State private var dragStartCenter: CGPoint?
    @State private var dragStartScale: Double?

    var body: some View {
        GeometryReader { geo in
            if let seg = model.selectedSegment {
                let src = model.doc.project.geometry.sourceSize
                // Replicate the compositor's padding: content inset = paddingFraction × min side.
                let inset = min(geo.size.width, geo.size.height) * model.state.paddingFraction
                let card = CGRect(x: inset, y: inset,
                                  width: max(geo.size.width - inset * 2, 1),
                                  height: max(geo.size.height - inset * 2, 1))
                let sx = card.width / src.width
                let sy = card.height / src.height
                let rect = CGRect(x: card.minX + seg.center.x * sx - src.width / seg.scale * sx / 2,
                                  y: card.minY + seg.center.y * sy - src.height / seg.scale * sy / 2,
                                  width: src.width / seg.scale * sx,
                                  height: src.height / seg.scale * sy)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(RC.amber.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(RC.amber, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        )
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .gesture(
                            DragGesture()
                                .onChanged { g in
                                    if dragStartCenter == nil { model.pushUndo(); dragStartCenter = seg.center }
                                    guard let start = dragStartCenter else { return }
                                    let nx = start.x + g.translation.width / sx
                                    let ny = start.y + g.translation.height / sy
                                    model.updateSegment(seg.id, center: CGPoint(
                                        x: min(max(nx, 0), src.width), y: min(max(ny, 0), src.height)))
                                }
                                .onEnded { _ in dragStartCenter = nil }
                        )

                    Text("ZOOM \(blockNumber(seg)) · \(String(format: "%.1f", seg.scale))×")
                        .font(RC.mono(10, weight: .semibold))
                        .foregroundStyle(RC.amberInk)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RC.amber, in: RoundedRectangle(cornerRadius: 5))
                        .offset(x: rect.minX, y: max(2, rect.minY - 22))

                    ForEach(0..<4, id: \.self) { corner in
                        handle(corner: corner, rect: rect, seg: seg)
                    }
                }
            }
        }
    }

    private func handle(corner: Int, rect: CGRect, seg: ZoomSegment) -> some View {
        let hx = corner % 2 == 0 ? rect.minX : rect.maxX
        let hy = corner < 2 ? rect.minY : rect.maxY
        return Rectangle()
            .fill(RC.amber)
            .frame(width: 8, height: 8)
            .overlay(Rectangle().stroke(RC.base, lineWidth: 1.5))
            .position(x: hx, y: hy)
            .gesture(
                DragGesture()
                    .onChanged { g in
                        if dragStartScale == nil { model.pushUndo(); dragStartScale = seg.scale }
                        guard let s0 = dragStartScale else { return }
                        // Dragging outward grows the viewport ⇒ smaller zoom scale.
                        let dx = (corner % 2 == 0 ? -g.translation.width : g.translation.width)
                        let factor = 1 + dx / max(rect.width, 40)
                        model.updateSegment(seg.id, scale: min(3.0, max(1.05, s0 / factor)))
                    }
                    .onEnded { _ in dragStartScale = nil }
            )
    }

    private func blockNumber(_ seg: ZoomSegment) -> Int {
        (model.zoomSegments.firstIndex(where: { $0.id == seg.id }) ?? 0) + 1
    }
}

// MARK: - Inspector (§2.4)

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    @AppStorage("inspector.motion") private var motionOpen = true
    @AppStorage("inspector.cursor") private var cursorOpen = false
    @AppStorage("inspector.frame") private var frameOpen = false
    @AppStorage("inspector.audio") private var audioOpen = false
    @AppStorage("inspector.captions") private var captionsOpen = false

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                section("Motion", summary: motionSummary, isOpen: $motionOpen) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Auto-zoom").font(RC.body).foregroundStyle(RC.ink)
                            Spacer()
                            ReelToggle(isOn: Binding(
                                get: { model.state.zoomEnabled },
                                set: { v in model.pushUndo(); model.state.zoomEnabled = v }))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Calm").font(.system(size: 10.5)).foregroundStyle(RC.ink3)
                                Spacer()
                                Text("Dynamic").font(.system(size: 10.5)).foregroundStyle(RC.ink3)
                            }
                            ReelSlider(value: Binding(
                                get: { model.state.motionDial },
                                set: { model.state.motionDial = $0 }),
                                onEditingChanged: { if $0 { model.pushUndo() } })
                            Text("Calm: fewer, gentler zooms that linger. Dynamic: tighter, faster, more of them.")
                                .font(.system(size: 10.5)).foregroundStyle(RC.ink4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .opacity(model.state.zoomEnabled ? 1 : 0.4)
                        .disabled(!model.state.zoomEnabled)
                    }
                }
                section("Cursor", summary: String(format: "%.1f×", model.state.cursorScale), isOpen: $cursorOpen) {
                    VStack(spacing: 12) {
                        sliderRow("Size", value: Binding(
                            get: { model.state.cursorScale - 1.0 },
                            set: { model.state.cursorScale = 1.0 + $0 }),
                            readout: String(format: "%.1f×", model.state.cursorScale))
                        sliderRow("Smoothing", value: Binding(
                            get: { model.state.cursorSmoothing },
                            set: { model.state.cursorSmoothing = $0 }),
                            readout: smoothingLabel)
                        HStack {
                            Text("Click ripples").font(RC.body).foregroundStyle(RC.ink)
                            Spacer()
                            ReelToggle(isOn: Binding(
                                get: { model.state.clickRipples },
                                set: { newValue in model.pushUndo(); model.state.clickRipples = newValue }))
                        }
                    }
                }
                section("Frame", summary: "\(Int((model.state.paddingFraction * 100).rounded()))%", isOpen: $frameOpen) {
                    VStack(spacing: 12) {
                        sliderRow("Padding", value: Binding(
                            get: { model.state.paddingFraction / 0.15 },
                            set: { model.state.paddingFraction = $0 * 0.15 }),
                            readout: "\(Int((model.state.paddingFraction * 100).rounded()))%")
                        sliderRow("Corners", value: Binding(
                            get: { model.state.cornerRadius / 24 },
                            set: { model.state.cornerRadius = ($0 * 24).rounded() }),
                            readout: "\(Int(model.state.cornerRadius))")
                        HStack {
                            Text("Shadow").font(RC.body).foregroundStyle(RC.ink)
                            Spacer()
                            HStack(spacing: 6) {
                                ForEach(Array(["S", "M", "L"].enumerated()), id: \.offset) { i, l in
                                    Chip(text: l, selected: model.state.shadowLevel == i, height: 24) {
                                        model.pushUndo(); model.state.shadowLevel = i
                                    }
                                }
                            }
                        }
                        // Backdrop lives inside Frame and only when there is padding to colour —
                        // at 0% padding there is no backdrop, so the swatches would do nothing.
                        if model.state.paddingFraction > 0.005 {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Backdrop").font(.system(size: 12)).foregroundStyle(RC.ink2)
                                HStack(spacing: 8) {
                                    ForEach(Array(ThemePresets.all.enumerated()), id: \.offset) { _, preset in
                                        BackgroundSwatch(style: preset.background,
                                                         selected: model.state.background == preset.background) {
                                            model.pushUndo()
                                            model.state.background = preset.background
                                        }
                                    }
                                    Button { pickCustomBackground() } label: {
                                        Image(systemName: "photo").font(.system(size: 11))
                                            .foregroundStyle(RC.ink3)
                                            .frame(width: 32, height: 32)
                                            .overlay(RoundedRectangle(cornerRadius: 7)
                                                .strokeBorder(RC.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Custom image")
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                section("Captions", summary: captionSummary, isOpen: $captionsOpen) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Burn in captions").font(RC.body).foregroundStyle(RC.ink)
                            Spacer()
                            if model.isTranscribing {
                                ProgressView().controlSize(.small)
                            } else {
                                ReelToggle(isOn: Binding(
                                    get: { model.state.captionsEnabled },
                                    set: { model.setCaptions(enabled: $0) }))
                            }
                        }
                        Text(model.captionError
                             ?? "Transcribed on this Mac — nothing is uploaded, no credits.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(model.captionError == nil ? RC.ink4 : RC.live)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                section("Cuts", summary: cutsSummary, isOpen: $audioOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-cut dead air").font(RC.body).foregroundStyle(RC.ink)
                                Text("Silence with no clicks — click a hatched column to keep it.")
                                    .font(.system(size: 10.5)).foregroundStyle(RC.ink4)
                            }
                            Spacer()
                            ReelToggle(isOn: Binding(
                                get: { model.state.removeSilence },
                                set: { newValue in
                                    model.pushUndo(); model.state.removeSilence = newValue
                                    Task { await model.loadSilencePreview() }
                                }))
                        }
                        HStack(spacing: 8) {
                            Button("Cut in → out") { model.cutMarkedRange() }
                                .buttonStyle(SecondaryButtonStyle(height: 28))
                                .disabled(!model.canCutMarkedRange)
                            Button("Blade") { model.blade() }
                                .buttonStyle(SecondaryButtonStyle(height: 28))
                            Spacer()
                            if !model.state.manualCuts.isEmpty || !model.state.splits.isEmpty {
                                Button("Reset") { model.clearManualCuts() }.buttonStyle(.reelQuiet)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            shortcutRow("I  /  O", "mark in / out at the playhead")
                            shortcutRow("B", "blade — split at the playhead")
                            shortcutRow("⌫", "delete selected piece, zoom, or in→out")
                            shortcutRow("J  K  L", "shuttle back / pause / forward")
                            shortcutRow("2-finger swipe", "scrub over the preview or timeline")
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var smoothingLabel: String {
        let s = model.state.cursorSmoothing
        return s < 0.1 ? "off" : (s < 0.4 ? "low" : (s < 0.75 ? "med" : "high"))
    }

    private var motionSummary: String {
        guard model.state.zoomEnabled else { return "off" }
        let d = model.state.motionDial
        return d < 0.33 ? "calm" : (d > 0.66 ? "dynamic" : "balanced")
    }

    private var cutsSummary: String {
        let auto = model.silenceSavings
        let manual = model.state.manualCuts.count
        var parts: [String] = []
        if model.state.removeSilence, auto > 0.05 { parts.append(String(format: "−%.1fs auto", auto)) }
        if manual > 0 { parts.append("\(manual) manual") }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }

    private func shortcutRow(_ key: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(key).font(RC.mono(10)).foregroundStyle(RC.ink3).frame(width: 90, alignment: .leading)
            Text(what).font(.system(size: 10.5)).foregroundStyle(RC.ink4)
        }
    }

    private var captionSummary: String {
        if model.isTranscribing { return "transcribing…" }
        if model.state.captionsEnabled { return "\(model.doc.captions.count) lines" }
        return "off"
    }


    private func pickCustomBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.pushUndo()
            model.state.background = .image(path: url.path)
        }
    }

    @ViewBuilder
    private func section(_ name: String, summary: String, isOpen: Binding<Bool>,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(RC.ink3)
                        .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                    Text(name).font(RC.label).foregroundStyle(RC.ink)
                    Spacer()
                    Text(summary).font(RC.mono(10)).foregroundStyle(RC.ink4)
                }
                .padding(.horizontal, 18)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen.wrappedValue {
                content()
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
            }
            Rectangle().fill(RC.hairlineSoft).frame(height: 1).padding(.horizontal, 12)
        }
    }

    private func sliderRow(_ name: String, value: Binding<Double>, readout: String) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 12)).foregroundStyle(RC.ink2)
                .frame(width: 68, alignment: .leading)
            ReelSlider(value: value, onEditingChanged: { began in if began { model.pushUndo() } })
            Text(readout).font(RC.mono(10.5)).foregroundStyle(RC.ink3)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// Small square background preview (gradient or solid).
struct BackgroundSwatch: View {
    let style: BackgroundStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7)
                .fill(fillStyle)
                .frame(width: 32, height: 32)
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? RC.amber : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var fillStyle: AnyShapeStyle {
        switch style {
        case let .solid(c):
            return AnyShapeStyle(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
        case let .linearGradient(f, t, _):
            return AnyShapeStyle(LinearGradient(
                colors: [Color(.sRGB, red: f.r, green: f.g, blue: f.b),
                         Color(.sRGB, red: t.r, green: t.g, blue: t.b)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        case let .radialGradient(f, t):
            return AnyShapeStyle(RadialGradient(
                colors: [Color(.sRGB, red: f.r, green: f.g, blue: f.b),
                         Color(.sRGB, red: t.r, green: t.g, blue: t.b)],
                center: .init(x: 0.5, y: 0.42), startRadius: 2, endRadius: 28))
        case .image:
            return AnyShapeStyle(Color.gray)
        }
    }
}

// MARK: - Timeline (§2.4)

struct EditorTimeline: View {
    @ObservedObject var model: EditorModel
    @State private var trimDragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            transport.frame(width: 170)
            GeometryReader { geo in
                let w = max(geo.size.width - 24, 10)
                let dur = max(0.1, model.totalDuration)
                let px = w / dur
                VStack(alignment: .leading, spacing: 6) {
                    ruler(px: px, dur: dur)
                    zoomTrack(px: px)
                    clipStrip(px: px, dur: dur)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .overlay(alignment: .topLeading) { playhead(px: px) }
            }
        }
    }

    private var transport: some View {
        VStack(spacing: 10) {
            Button {
                model.togglePlay()
            } label: {
                ZStack {
                    Circle().fill(RC.ink).frame(width: 40, height: 40)
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(RC.base)
                        .offset(x: model.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .hoverRaise()
            HStack(spacing: 0) {
                Text(timecode(model.currentTime)).font(RC.mono(11.5)).foregroundStyle(RC.ink2)
                Text(" / " + timecode(model.editedDuration)).font(RC.mono(11.5)).foregroundStyle(RC.ink.opacity(0.28))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timecode(_ t: Double) -> String {
        String(format: "%02d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    /// Label interval that keeps labels ≥ ~64 pt apart; minor ticks at a fifth of it.
    private func rulerStep(px: CGFloat) -> Double {
        for step in [1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0] where CGFloat(step) * px >= 64 { return step }
        return 120
    }

    private func ruler(px: CGFloat, dur: Double) -> some View {
        let step = rulerStep(px: px)
        let minor = step / 5
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 16)
            // Minor ticks — one even baseline, so the ruler reads as a single line.
            ForEach(0...Int(dur / minor), id: \.self) { i in
                let t = Double(i) * minor
                let isMajor = i % 5 == 0
                Rectangle().fill(RC.ink.opacity(isMajor ? 0.35 : 0.16))
                    .frame(width: 1, height: isMajor ? 8 : 4)
                    .offset(x: CGFloat(t) * px, y: isMajor ? 8 : 12)
            }
            ForEach(0...Int(dur / step), id: \.self) { i in
                let t = Double(i) * step
                Text(String(format: "%d:%02d", Int(t) / 60, Int(t) % 60))
                    .font(RC.mono(9.5))
                    .foregroundStyle(RC.ink.opacity(0.32))
                    .fixedSize()
                    .offset(x: CGFloat(t) * px + 3, y: -3)
            }
            // In / out marks (edited time → raw x).
            if let i = model.inPoint {
                inOutMark(x: CGFloat(model.rawTime(fromEdited: i)) * px, label: "I")
            }
            if let o = model.outPoint {
                inOutMark(x: CGFloat(model.rawTime(fromEdited: o)) * px, label: "O")
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            model.scrub(to: model.editedTime(fromRaw: Double(g.location.x / px)))
        })
    }

    private func inOutMark(x: CGFloat, label: String) -> some View {
        Text(label).font(RC.mono(8, weight: .bold)).foregroundStyle(RC.amberInk)
            .frame(width: 12, height: 12)
            .background(RC.amber, in: RoundedRectangle(cornerRadius: 3))
            .offset(x: x - 6, y: 2)
    }

    private func zoomTrack(px: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 30)
            ForEach(model.zoomSegments) { seg in
                ZoomBlockView(model: model, seg: seg, px: px)
            }
        }
        .contextMenu {
            Button("Add zoom at playhead") { model.addSegmentAtPlayhead() }
        }
    }

    private func clipStrip(px: CGFloat, dur: Double) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(Array(model.filmstrip.enumerated()), id: \.offset) { _, cg in
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: max(10, px * dur / CGFloat(max(1, model.filmstrip.count))), height: 52)
                        .clipped()
                }
            }
            .frame(width: px * dur, height: 52, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: RC.rButton))

            let inX = CGFloat(model.state.trimIn) * px
            let outX = CGFloat(model.state.trimOut) * px

            // Pieces (kept spans split at blade points): click to select, ⌫ to remove.
            ForEach(Array(model.pieces.enumerated()), id: \.offset) { i, piece in
                let x = CGFloat(piece.lowerBound) * px
                let w = CGFloat(piece.upperBound - piece.lowerBound) * px
                Rectangle().fill(Color.clear)
                    .frame(width: max(2, w), height: 52)
                    .contentShape(Rectangle())
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(model.selectedPieceIndex == i ? RC.amber : .clear, lineWidth: 2)
                        .padding(1))
                    .offset(x: x)
                    .onTapGesture {
                        model.selectedPieceIndex = (model.selectedPieceIndex == i) ? nil : i
                        model.selectedSegmentID = nil
                    }
            }
            // Blade lines.
            ForEach(Array(model.state.splits.enumerated()), id: \.offset) { _, sp in
                Rectangle().fill(RC.ink.opacity(0.85)).frame(width: 2, height: 52)
                    .offset(x: CGFloat(sp) * px - 1)
                    .allowsHitTesting(false)
            }
            // In→out shading (edited → raw x).
            if let i = model.inPoint, let o = model.outPoint, o > i {
                let ix = CGFloat(model.rawTime(fromEdited: i)) * px
                let ox = CGFloat(model.rawTime(fromEdited: o)) * px
                Rectangle().fill(RC.amber.opacity(0.18)).frame(width: max(0, ox - ix), height: 52)
                    .offset(x: ix).allowsHitTesting(false)
            }

            Rectangle().fill(RC.base.opacity(0.72)).frame(width: max(0, inX), height: 52)
                .allowsHitTesting(false)
            Rectangle().fill(RC.base.opacity(0.72))
                .frame(width: max(0, px * dur - outX), height: 52)
                .offset(x: outX).allowsHitTesting(false)

            // Every removed span (auto + manual), hatched; click to bring it back.
            ForEach(Array(model.effectiveCuts.enumerated()), id: \.offset) { _, cut in
                let x = CGFloat(cut.lowerBound) * px
                let cw = CGFloat(cut.upperBound - cut.lowerBound) * px
                CutColumn().frame(width: max(6, cw), height: 52).offset(x: x)
                    .contentShape(Rectangle())
                    .onTapGesture { model.restoreCut(cut) }
                    .help("Click to keep this part")
            }

            trimHandle(at: inX, leading: true, px: px)
            trimHandle(at: outX, leading: false, px: px)
        }
        .frame(height: 52)
    }

    private func trimHandle(at x: CGFloat, leading: Bool, px: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(RC.ink)
            .frame(width: 10, height: 52)
            .overlay(RoundedRectangle(cornerRadius: 1).fill(RC.base.opacity(0.6)).frame(width: 2, height: 16))
            .offset(x: x - (leading ? 10 : 0))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if trimDragStart == nil {
                        model.pushUndo()
                        trimDragStart = leading ? model.state.trimIn : model.state.trimOut
                    }
                    let t = Double(g.location.x / px)
                    if leading {
                        model.state.trimIn = min(max(0, t), model.state.trimOut - 0.5)
                    } else {
                        model.state.trimOut = max(min(model.totalDuration, t), model.state.trimIn + 0.5)
                    }
                }
                .onEnded { _ in trimDragStart = nil })
    }

    private func playhead(px: CGFloat) -> some View {
        let x = 12 + CGFloat(model.playheadRaw) * px
        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3).fill(RC.ink).frame(width: 10, height: 8)
            Rectangle().fill(RC.ink).frame(width: 2)
                .shadow(color: .white.opacity(0.5), radius: 8)
        }
        .frame(height: 128)
        .offset(x: x - 5, y: 6)
        .allowsHitTesting(false)
    }
}

/// One zoom block: drag = retime, right-edge drag = resize, click = select (§2.4).
struct ZoomBlockView: View {
    @ObservedObject var model: EditorModel
    let seg: ZoomSegment
    let px: CGFloat
    @State private var dragStart: Double?
    @State private var resizeStart: Double?

    var body: some View {
        let selected = model.selectedSegmentID == seg.id
        let x = CGFloat(model.rawTime(fromEdited: seg.start)) * px
        let w = max(26, CGFloat(seg.duration) * px)

        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? RC.amber : RC.amberWash)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? RC.amber : RC.amberBorder, lineWidth: 1))
                .shadow(color: selected ? RC.amber.opacity(0.5) : .clear, radius: 8)
            Text(String(format: "%.1f×", seg.scale))
                .font(RC.mono(10, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? RC.amberInk : RC.amber)
            if selected {
                HStack {
                    grabBar
                    Spacer()
                    grabBar
                }
                .padding(.horizontal, 3)
            }
        }
        .frame(width: w, height: 26)
        .offset(x: x, y: 2)
        .onTapGesture {
            model.selectedSegmentID = seg.id
            model.selectedPieceIndex = nil
            // Scrub to just before activation so the target box maps over a (near) rest camera.
            model.scrub(to: max(0, seg.start - 0.6))
        }
        .gesture(
            DragGesture()
                .onChanged { g in
                    if dragStart == nil { model.pushUndo(); dragStart = seg.start }
                    guard let s0 = dragStart else { return }
                    model.updateSegment(seg.id, start: max(0, s0 + Double(g.translation.width / px)))
                }
                .onEnded { _ in dragStart = nil }
        )
        .contextMenu {
            Button("Remove zoom") { model.deleteSegment(seg.id) }
            if seg.clusterIndex != nil {
                Button("Reset aim") { model.resetSegment(seg.id) }
            }
        }
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 8, height: 26)
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { g in
                        if resizeStart == nil { model.pushUndo(); resizeStart = seg.duration }
                        guard let d0 = resizeStart else { return }
                        model.updateSegment(seg.id, duration: max(0.3, d0 + Double(g.translation.width / px)))
                    }
                    .onEnded { _ in resizeStart = nil })
                .offset(x: x + w - 8, y: 2)
        }
    }

    private var grabBar: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(RC.amberInk.opacity(0.5))
            .frame(width: 3, height: 12)
    }
}

/// Hatched "CUT" column for auto-removed silence (§2.4).
struct CutColumn: View {
    var body: some View {
        ZStack {
            Rectangle().fill(RC.base.opacity(0.65))
            HatchPattern().stroke(Color.black.opacity(0.4), lineWidth: 2)
            Text("CUT")
                .font(RC.mono(8, weight: .semibold))
                .foregroundStyle(RC.ink3)
                .rotationEffect(.degrees(-90))
        }
        .clipped()
    }
}

struct HatchPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 7
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += step
        }
        return p
    }
}


/// Platform safe-area guides for vertical formats (preview-only, never exported): the bands
/// Reels/Shorts/TikTok cover with their own UI. Keep zoom targets and captions out of them.
struct SafeAreaGuides: View {
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            ZStack(alignment: .top) {
                // Top band (~11%): username / camera chrome.
                guideBand(y: 0, height: h * 0.11, width: w, label: "platform UI")
                // Bottom band (~18%): caption field, actions, music line.
                guideBand(y: h * 0.82, height: h * 0.18, width: w, label: "platform UI")
                // Right rail (~13%): like/comment/share stack.
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: w * 0.13, height: h * 0.60)
                    .offset(x: w * 0.87, y: h * 0.20)
                    .overlay(alignment: .center) {
                        Text("actions")
                            .font(RC.mono(8)).foregroundStyle(RC.ink3)
                            .rotationEffect(.degrees(-90))
                            .offset(x: w * 0.87 - w / 2 + w * 0.065, y: 0)
                    }
            }
            .overlay(
                Rectangle()
                    .strokeBorder(RC.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .padding(.top, h * 0.11)
                    .padding(.bottom, h * 0.18)
                    .padding(.trailing, w * 0.13)
            )
        }
        .allowsHitTesting(false)
    }

    private func guideBand(y: CGFloat, height: CGFloat, width: CGFloat, label: String) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.18))
            .frame(width: width, height: height)
            .overlay(Text(label).font(RC.mono(8)).foregroundStyle(RC.ink3))
            .offset(y: y)
    }
}
