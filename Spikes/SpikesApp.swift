import SwiftUI

/// M0 spike harness (BUILD_PLAN §10). One window, a button per spike; results stream to the log
/// and the console. Each spike either CONFIRMS an assumption or tells us to change the design —
/// run these before trusting any capture assumption in production code.
@main
struct SpikesApp: App {
    var body: some Scene {
        WindowGroup("Reel Spikes") {
            SpikesView()
                .frame(minWidth: 640, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}
