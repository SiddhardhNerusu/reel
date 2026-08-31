import SwiftUI

/// Reel — "the polished demo recorder you buy once".
///
/// Architecture (BUILD_PLAN §3): Stage 1 records `raw.mov` + a synchronized event
/// timeline; Stage 2 re-composites offline through ONE pure compose function shared
/// by preview and export. Zoom is NEVER baked into live capture.
@main
struct ReelApp: App {
    @StateObject private var coordinator = RecordingCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)   // Reel's home is dark, like the clips it makes
        }
        .windowStyle(.hiddenTitleBar)           // custom chrome; traffic lights float over content
        .windowResizability(.contentSize)
    }
}
