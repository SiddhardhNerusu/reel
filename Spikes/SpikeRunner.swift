import Foundation

/// A tiny observable log the spike buttons write into. Keeps spikes dependency-free of any real UI.
@MainActor
final class SpikeLog: ObservableObject {
    @Published var lines: [String] = []
    @Published var running = false

    func clear() { lines.removeAll() }

    func log(_ s: String) {
        let stamped = String(format: "%.3f  %@", HostClock.now().truncatingRemainder(dividingBy: 100000), s)
        lines.append(stamped)
        print("[spike] \(s)")
    }

    func result(_ pass: Bool, _ s: String) {
        log("\(pass ? "✅ PASS" : "❌ CHECK") — \(s)")
    }
}
