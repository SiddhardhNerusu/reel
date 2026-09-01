import SwiftUI

/// Reel — "the polished demo recorder you buy once".
///
/// Architecture (BUILD_PLAN §3): Stage 1 records `raw.mov` + a synchronized event
/// timeline; Stage 2 re-composites offline through ONE pure compose function shared
/// by preview and export. Zoom is NEVER baked into live capture.
@main
struct ReelApp: App {
    @StateObject private var coordinator = RecordingCoordinator()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Launcher (Darkroom 1a/1b) — fixed 800pt, hidden titlebar.
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)   // committed studio look
                .onAppear {
                    HotKeys.shared.register { [weak coordinator] in coordinator?.hotkeyToggle() }
                }
                .onChange(of: coordinator.lastProject?.url) { _, url in
                    // A finished take opens straight into the editor (§2.3 Stop & Edit).
                    if let url { openWindow(value: url) }
                }
        }
        .windowStyle(.hiddenTitleBar)           // custom chrome; traffic lights float over content
        .windowResizability(.contentSize)

        // Editor (Darkroom 1d) — its own window per project, min 1280×800.
        WindowGroup("Editor", for: URL.self) { $url in
            if let url, let doc = try? ReelDocument.open(url) {
                EditorView(model: EditorModel(doc: doc))
                    .preferredColorScheme(.dark)
            }
        }
        .windowStyle(.hiddenTitleBar)

        // Settings (Darkroom 1f).
        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }

        // Menu-bar presence (§2.3): idle glyph; recording = pulsing dot + elapsed.
        MenuBarExtra {
            MenuBarDropdown(coordinator: coordinator)
        } label: {
            MenuBarLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar label: template glyph when idle, red dot + mono elapsed while recording.
struct MenuBarLabel: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        if coordinator.phase == .recording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(elapsed(context.date)).font(.system(size: 11.5, design: .monospaced))
                }
            }
        } else {
            Image(systemName: "record.circle")
        }
    }

    private func elapsed(_ now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(coordinator.recordingStartedAt ?? now)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Menu-bar dropdown (artboard 1c): big timecode, REC, Pause / Stop & Edit.
struct MenuBarDropdown: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        VStack(spacing: 12) {
            if coordinator.phase == .recording {
                HStack(spacing: 9) {
                    PulsingDot(size: 9, active: !coordinator.isPaused)
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        Text(elapsed(context.date)).font(RC.mono(22, weight: .semibold)).foregroundStyle(RC.ink)
                    }
                    Spacer()
                    Text("REC")
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                        .foregroundStyle(RC.live)
                }
                HStack(spacing: 8) {
                    Button(coordinator.isPaused ? "Resume" : "Pause") { coordinator.togglePause() }
                        .buttonStyle(.reelSecondary)
                        .frame(maxWidth: .infinity)
                    Button {
                        Task { await coordinator.stopRecording() }
                    } label: {
                        Text("Stop & Edit")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(RC.live, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
                Text("\(AppSettings.hotkeyLabelKeys.joined()) stops from anywhere")
                    .font(RC.mono(10.5)).foregroundStyle(RC.ink4)
            } else {
                Text("Not recording").font(RC.body).foregroundStyle(RC.ink2)
                Text("\(AppSettings.hotkeyLabelKeys.joined()) starts a take")
                    .font(RC.mono(10.5)).foregroundStyle(RC.ink4)
            }
        }
        .padding(16)
        .frame(width: 236)
        .background(RC.raised)
    }

    private func elapsed(_ now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(coordinator.recordingStartedAt ?? now)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
