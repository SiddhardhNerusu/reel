import SwiftUI

/// Reel — "the polished demo recorder you buy once".
///
/// Architecture (BUILD_PLAN §3): Stage 1 records `raw.mov` + a synchronized event
/// timeline; Stage 2 re-composites offline through ONE pure compose function shared
/// by preview and export. Zoom is NEVER baked into live capture.
@main
struct ReelApp: App {
    @StateObject private var coordinator = RecordingCoordinator()
    private let statusItem = StatusItemController()

    var body: some Scene {
        // Launcher (Darkroom 1a/1b) — fixed 800pt, hidden titlebar.
        // ONE window: launcher ⇄ editor swap in place (owner feedback — no second window).
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)   // committed studio look
                .onAppear {
                    HotKeys.shared.register { [weak coordinator] in coordinator?.hotkeyToggle() }
                    statusItem.attach(coordinator)
                }
                .onChange(of: coordinator.lastProject?.url) { _, _ in
                    // A finished take opens straight into the editor (§2.3 Stop & Edit).
                    if let doc = coordinator.lastProject { coordinator.editorDoc = doc }
                }
        }
        .windowStyle(.hiddenTitleBar)           // custom chrome; traffic lights float over content
        .windowResizability(.contentMinSize)

        // Settings (Darkroom 1f).
        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }

    }
}

