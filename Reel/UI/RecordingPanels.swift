import AppKit
import SwiftUI

// MARK: - Floating recording pill (IMPLEMENTATION_BRIEF §2.3, artboard 1c)

/// NSPanel host: non-activating, statusBar level, EXCLUDED from capture (sharingType .none) so
/// the pill never appears in its own recording (acceptance #4). Draggable; position persisted.
@MainActor
final class RecordingPillController {
    private var panel: NSPanel?
    private let coordinator: RecordingCoordinator

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        guard panel == nil else { return }
        let view = NSHostingView(rootView: RecordingPillView(coordinator: coordinator))
        // fittingSize can come back .zero for hosted SwiftUI before first layout — an invisible
        // 0×0 panel was exactly the "no way to stop it" bug (2026-09-01). Fall back to the
        // pill's designed size.
        var size = view.fittingSize
        if size.width < 100 || size.height < 30 { size = NSSize(width: 280, height: 62) }
        view.frame = NSRect(origin: .zero, size: size)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = view
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.sharingType = .none                        // never in the take
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let saved = AppSettings.pillOrigin {
            p.setFrameOrigin(saved)
        } else if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - view.fittingSize.width / 2,
                                     y: screen.frame.minY + 120))
        }
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        if let p = panel { AppSettings.pillOrigin = p.frame.origin }
        panel?.orderOut(nil)
        panel = nil
    }
}

struct RecordingPillView: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        HStack(spacing: 14) {
            PulsingDot(size: 10, active: !coordinator.isPaused)
                .opacity(coordinator.isPaused ? 0.35 : 1)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(elapsed(context.date))
                    .font(RC.mono(14))
                    .foregroundStyle(RC.ink)
            }
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18)
            Button {
                coordinator.togglePause()
            } label: {
                Image(systemName: coordinator.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(RC.ink.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                Task { await coordinator.stopRecording() }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(RC.live).frame(width: 30, height: 30)
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                }
            }
            .buttonStyle(.plain)
            .hoverRaise()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(.ultraThinMaterial, in: Capsule())
        .background(RC.base.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 14)
        .padding(8)
    }

    private func elapsed(_ now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(coordinator.recordingStartedAt ?? now)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Countdown overlay (LAUNCH_PLAN P1.4 — 3-2-1, skippable)

@MainActor
final class CountdownController {
    private var panel: NSPanel?

    /// Runs a countdown over `screen`, then calls `completion(true)`. Click/Esc skips straight
    /// in; the panel is never part of the recording (it closes before capture starts).
    func run(seconds: Int, on screen: NSScreen, completion: @escaping (Bool) -> Void) {
        guard seconds > 0 else { completion(true); return }
        let p = NSPanel(contentRect: screen.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.sharingType = .none
        let view = NSHostingView(rootView: CountdownView(seconds: seconds) { [weak self] in
            self?.dismiss()
            completion(true)
        })
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct CountdownView: View {
    let seconds: Int
    let done: () -> Void
    @State private var remaining: Int = 0

    var body: some View {
        ZStack {
            RC.stage.opacity(0.55)
            Text("\(max(1, remaining))")
                .font(RC.mono(160, weight: .semibold))
                .foregroundStyle(RC.ink)
                .contentTransition(.numericText(countsDown: true))
            VStack {
                Spacer()
                Text("click to start now")
                    .font(RC.mono(12))
                    .foregroundStyle(RC.ink3)
                    .padding(.bottom, 60)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { done() }
        .onAppear {
            remaining = seconds
            tick()
        }
    }

    private func tick() {
        guard remaining > 0 else { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation(.easeOut(duration: 0.2)) { remaining -= 1 }
            tick()
        }
    }
}

// MARK: - Area selection overlay (LAUNCH_PLAN P1.2 — drag a rect, Enter/Esc)

@MainActor
final class AreaPickerController {
    private var panel: NSPanel?

    /// Full-screen dimmed overlay; the user drags a rect. Returns the rect in GLOBAL top-left
    /// points (the coordinate space GeometrySnapshot expects), or nil on Esc.
    func pick(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        let p = AreaPanel(contentRect: screen.frame,
                          styleMask: [.borderless],
                          backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.sharingType = .none
        let view = NSHostingView(rootView: AreaPickerView { [weak self] localRect in
            self?.dismiss()
            guard let localRect else { completion(nil); return }
            // SwiftUI gives a top-left rect in the panel's space; convert to global top-left
            // points: global origin = screen's top-left in the global (CG, top-left) space.
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            let globalTopLeftY = primaryHeight - screen.frame.maxY   // CG y of this screen's top
            let global = CGRect(x: screen.frame.minX + localRect.minX,
                                y: globalTopLeftY + localRect.minY,
                                width: localRect.width, height: localRect.height)
            completion(global)
        })
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        p.contentView = view
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Borderless panels refuse key status by default — the picker needs Esc/Enter.
    private final class AreaPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

struct AreaPickerView: View {
    let done: (CGRect?) -> Void
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var rect: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    var body: some View {
        ZStack {
            // Dim everything except the selection.
            if let r = rect {
                DimExcept(rect: r).fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(RC.amber, lineWidth: 1.5)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                Text("\(Int(r.width)) × \(Int(r.height)) — ⏎ to record")
                    .font(RC.mono(12))
                    .foregroundStyle(RC.ink)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RC.base.opacity(0.9), in: Capsule())
                    .position(x: r.midX, y: max(20, r.minY - 22))
            } else {
                Color.black.opacity(0.45)
                Text("Drag to select an area — Esc to cancel")
                    .font(RC.mono(13))
                    .foregroundStyle(RC.ink)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RC.base.opacity(0.9), in: Capsule())
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                if start == nil { start = g.startLocation }
                current = g.location
            }
            .onEnded { _ in
                if let r = rect, r.width > 40, r.height > 30 { done(r) }
            })
        .onExitCommand { done(nil) }
        .onKeyPress(.return) {
            if let r = rect, r.width > 40, r.height > 30 { done(r); return .handled }
            return .ignored
        }
    }
}

/// Even-odd fill: whole screen minus the selection rect.
struct DimExcept: Shape {
    let rect: CGRect
    func path(in bounds: CGRect) -> Path {
        var p = Path()
        p.addRect(bounds)
        p.addRect(rect)
        return p
    }
}
