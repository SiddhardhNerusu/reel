import AVKit
import SwiftUI

/// The Studio — a scrubbable live preview (pixel-identical to export, §5.6) beside the few dials
/// that matter: background, aspect, auto-zoom, trim. Editing never touches `raw.mov`, so you can
/// retune and re-export forever.
struct EditorView: View {
    @StateObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .mp4

    enum ExportFormat: String, CaseIterable { case mp4 = "MP4", gif = "GIF" }

    var body: some View {
        ZStack(alignment: .bottom) {
            WindowBackground()
            VStack(spacing: 0) {
                topBar
                Divider().overlay(RC.hairline)
                HStack(spacing: 0) {
                    stage
                    Divider().overlay(RC.hairline)
                    inspector.frame(width: 276)
                }
            }
            if let out = model.exportedURL, !model.isExporting {
                ExportToast(name: out.lastPathComponent,
                            onCopy: { model.copyExportToClipboard() },
                            onReveal: { model.revealExport() },
                            onDismiss: { model.dismissToast() })
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: out) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        model.dismissToast()
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.exportedURL)
        .frame(minWidth: 860, minHeight: 560)
        .preferredColorScheme(.dark)
        .background(keyShortcuts)
        .task { await model.rebuildPreview(); await model.loadFilmstrip() }
        .onDisappear { model.teardown() }
        .onChange(of: model.presetIndex) { Task { await model.rebuildPreview() } }
        .onChange(of: model.aspect) { Task { await model.rebuildPreview() } }
        .onChange(of: model.autoZoom) { Task { await model.rebuildPreview() } }
        .onChange(of: model.trimIn) { Task { await model.rebuildPreview() } }
        .onChange(of: model.trimOut) { Task { await model.rebuildPreview() } }
    }

    /// Invisible buttons that register app-standard editor shortcuts (Space, ←/→ frame-step).
    /// ⌘E (export) and Esc (close) live on their real buttons.
    private var keyShortcuts: some View {
        ZStack {
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            // ⌘1…⌘5 pick a background.
            ForEach(Array(ThemePresets.all.enumerated()), id: \.offset) { i, _ in
                Button("") { model.presetIndex = i }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .opacity(0).allowsHitTesting(false)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(RC.textDim)
            .keyboardShortcut(.cancelAction)

            VStack(alignment: .leading, spacing: 0) {
                Text("Untitled demo").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(RC.text)
                Text("\(fmt(model.totalDuration)) · \(RecordingCoordinator.outputSize(for: model.doc.project).label)")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(RC.textFaint)
            }
            Spacer()

            MiniSegmented(items: ExportFormat.allCases.map { ($0, $0.rawValue) }, selection: $format)

            Button {
                Task { await model.export(gif: format == .gif) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.reelAccent)
            .keyboardShortcut("e", modifiers: .command)
            .disabled(model.isExporting)
        }
        .padding(.leading, 78).padding(.trailing, 16).frame(height: 52)
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 0) {
            ZStack {
                canvasBackdrop
                PlayerCanvas(player: model.player)
                    .aspectRatio(model.outputAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 34, y: 16)
                    .padding(32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(RC.surface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A calm editor canvas — a deep neutral with a faint center lift, so the framed preview reads
    /// as "sitting on a surface" rather than floating in black.
    private var canvasBackdrop: some View {
        ZStack {
            RC.canvasInset
            RadialGradient(colors: [.white.opacity(0.05), .clear],
                           center: .center, startRadius: 8, endRadius: 420)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13)).foregroundStyle(RC.text)
                    .frame(width: 36, height: 36)
                    .background(RC.raised, in: Circle())
                    .overlay(Circle().stroke(RC.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain).hoverBrighten()

            TrimTimeline(filmstrip: model.filmstrip,
                         total: max(0.1, model.totalDuration),
                         playhead: model.currentTime,
                         trimIn: $model.trimIn,
                         trimOut: $model.trimOut,
                         onSeek: { model.scrub(to: $0) })

            Text("\(fmt(model.currentTime)) / \(fmt(model.totalDuration))")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(RC.textFaint)
                .frame(width: 92, alignment: .trailing)
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                group("Background") {
                    HStack(spacing: 10) {
                        ForEach(Array(ThemePresets.all.enumerated()), id: \.offset) { i, preset in
                            Swatch(style: preset.background, selected: model.presetIndex == i) {
                                model.presetIndex = i
                            }
                        }
                    }
                }

                group("Aspect ratio") {
                    FlowChips(items: AspectPreset.allCases, selection: $model.aspect) { $0.label }
                }

                group("Motion") {
                    Toggle(isOn: $model.autoZoom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-zoom").font(.system(size: 13, weight: .semibold)).foregroundStyle(RC.text)
                            Text("Follow clicks with an eased camera")
                                .font(.system(size: 11.5)).foregroundStyle(RC.textFaint)
                        }
                    }
                    .toggleStyle(.switch).tint(RC.accent)
                }

                if model.isExporting {
                    ProgressView(value: model.exportProgress) {
                        Text("Rendering \(format.rawValue)…").font(.system(size: 11)).foregroundStyle(RC.textDim)
                    }
                }
                if let err = model.errorText {
                    Text(err).font(.system(size: 11.5)).foregroundStyle(RC.record)
                }
            }
            .padding(18)
        }
        .background(RC.surface)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: title)
            content()
        }
    }

    private func fmt(_ v: Double) -> String {
        let s = max(0, v)
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Components

/// AVPlayerView with its own controls hidden — we drive playback with a custom transport.
private struct PlayerCanvas: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear   // no black fill behind the framed media
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

/// Transient confirmation after export, with the demo-tool essentials: Copy (to clipboard) + Reveal.
private struct ExportToast: View {
    let name: String
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onDismiss: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(RC.success).font(.system(size: 17))
            VStack(alignment: .leading, spacing: 1) {
                Text("Exported").font(.system(size: 13, weight: .semibold)).foregroundStyle(RC.text)
                Text(name).font(.system(size: 11)).foregroundStyle(RC.textFaint).lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)

            Button {
                onCopy(); copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.reelAccent)

            Button { onReveal() } label: { Label("Reveal", systemImage: "folder") }
                .buttonStyle(.reelSoft)

            Button { onDismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(RC.textFaint).padding(.leading, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .background(RC.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RC.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 26, y: 12)
    }
}

/// A small custom segmented control that matches the app (native `.segmented` renders generic blue).
private struct MiniSegmented<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                Button { selection = item.0 } label: {
                    Text(item.1)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selection == item.0 ? RC.text : RC.textDim)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(selection == item.0 ? RC.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: selection == item.0 ? .black.opacity(0.15) : .clear, radius: 2, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RC.surface2, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(RC.hairline, lineWidth: 1))
    }
}

/// The trim timeline (BUILD_PLAN §11 M6): a filmstrip of the recording with draggable in/out
/// handles, a dimmed region outside the selection, and a live playhead. Clicking/dragging the body
/// scrubs; dragging a handle trims. One element does what two plain sliders used to.
private struct TrimTimeline: View {
    let filmstrip: [CGImage]
    let total: Double
    let playhead: Double
    @Binding var trimIn: Double
    @Binding var trimOut: Double
    let onSeek: (Double) -> Void

    private let h: CGFloat = 46
    private let handleW: CGFloat = 11
    private let space = "trim"

    @State private var activeLabel: LabelInfo?
    private struct LabelInfo { var x: CGFloat; var text: String }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let inX = x(trimIn, w), outX = x(trimOut, w), phX = x(min(max(playhead, 0), total), w)
            ZStack(alignment: .leading) {
                filmstripView(w: w)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)

                // Scrub anywhere on the body (sits under the handles).
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                        .onChanged { g in
                            let t = clamp(Double(g.location.x / w) * total)
                            onSeek(t); activeLabel = LabelInfo(x: g.location.x, text: timeStr(t))
                        }
                        .onEnded { _ in activeLabel = nil })

                // Dim outside the selection.
                Rectangle().fill(.black.opacity(0.5)).frame(width: max(0, inX), height: h)
                    .allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.5)).frame(width: max(0, w - outX), height: h)
                    .offset(x: outX).allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 7).stroke(RC.accent, lineWidth: 2)
                    .frame(width: max(0, outX - inX), height: h).offset(x: inX)
                    .allowsHitTesting(false)

                ZStack {
                    Capsule().fill(.white).frame(width: 2.5, height: h)
                    Circle().fill(.white).frame(width: 10, height: 10).offset(y: -h / 2 + 2)
                }
                .frame(width: 10, height: h)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .offset(x: phX - 5).allowsHitTesting(false)

                handle(at: inX, w: w) { nx in trimIn = min(max(0, nx), trimOut - 0.3) }
                handle(at: outX, w: w) { nx in trimOut = max(min(total, nx), trimIn + 0.3) }

                if let lbl = activeLabel {
                    Text(lbl.text)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(RC.text)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RC.raised, in: Capsule())
                        .overlay(Capsule().stroke(RC.hairlineStrong, lineWidth: 1))
                        .fixedSize()
                        .position(x: min(max(22, lbl.x), w - 22), y: -13)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h)
            .coordinateSpace(name: space)
        }
        .frame(height: h)
    }

    private func filmstripView(w: CGFloat) -> some View {
        let n = max(1, filmstrip.count)
        let cell = (w - CGFloat(n - 1)) / CGFloat(n)   // 1px separators between frames
        return HStack(spacing: 1) {
            if filmstrip.isEmpty {
                RC.surface2
            } else {
                ForEach(filmstrip.indices, id: \.self) { i in
                    Image(decorative: filmstrip[i], scale: 1)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: cell, height: h)
                        .clipped()
                }
            }
        }
        .frame(width: w, height: h)
        .background(Color.black)                                       // shows through as separators
        .overlay(LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.34)],
                                startPoint: .top, endPoint: .bottom))  // tame bright content
        .saturation(0.9)
    }

    private func handle(at hx: CGFloat, w: CGFloat, onDrag: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(RC.accent)
            .frame(width: handleW, height: h)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 14))
            .frame(width: handleW + 16, height: h)          // widen the hit target, handle centered
            .contentShape(Rectangle())
            .offset(x: hx - (handleW + 16) / 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { g in
                    let t = clamp(Double(g.location.x / max(1, w)) * total)
                    onDrag(t); activeLabel = LabelInfo(x: g.location.x, text: timeStr(t))
                }
                .onEnded { _ in activeLabel = nil })
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat(t / max(0.0001, total)) * w }
    private func clamp(_ t: Double) -> Double { min(max(0, t), total) }
    private func timeStr(_ t: Double) -> String {
        String(format: "%d:%02d", Int(max(0, t)) / 60, Int(max(0, t)) % 60)
    }
}

private struct Swatch: View {
    let style: BackgroundStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 9)
                .fill(BackgroundStylePreview.shape(style))
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(RC.hairline, lineWidth: 1))
                .overlay(
                    selected ? RoundedRectangle(cornerRadius: 9).stroke(RC.accent, lineWidth: 2).padding(-3) : nil
                )
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.08)
    }
}

/// Renders a `BackgroundStyle` as a SwiftUI gradient/color for swatches + (future) canvas chrome.
enum BackgroundStylePreview {
    static func shape(_ style: BackgroundStyle) -> AnyShapeStyle {
        switch style {
        case let .solid(c):
            return AnyShapeStyle(color(c))
        case let .linearGradient(from, to, _):
            return AnyShapeStyle(LinearGradient(colors: [color(from), color(to)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .image:
            return AnyShapeStyle(Color.gray)
        }
    }
    static func color(_ c: RGBAColor) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

private struct FlowChips<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        FlowLayout(spacing: 7, lineSpacing: 7) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button { selection = item } label: {
                    Text(label(item))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? .white : RC.textDim)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(on ? RC.accent : RC.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? .clear : RC.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A minimal flow layout — lays children left→right and wraps to a new line when they don't fit.
/// Used so aspect chips keep their labels on one line and wrap the ROW instead.
struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, rowH: CGFloat = 0, totalH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxWidth, x > 0 {
                totalH += rowH + lineSpacing; widest = max(widest, x - spacing); x = 0; rowH = 0
            }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        totalH += rowH; widest = max(widest, x - spacing)
        return CGSize(width: min(maxWidth, widest), height: totalH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + lineSpacing; rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
