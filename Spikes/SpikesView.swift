import AVFoundation
import CoreImage
import ScreenCaptureKit
import SwiftUI

struct SpikesView: View {
    @StateObject private var log = SpikeLog()

    private let spikes: [(id: String, title: String)] = [
        ("SP-0", "Capture one display → raw.mov (Retina, variable PTS)"),
        ("SP-1", "System audio + mic land on separate tracks"),
        ("SP-2", "Listen-only mouse CGEventTap — does it fire without a grant?"),
        ("SP-3", "CGEvent stamps vs SCK frame PTS share one clock"),
        ("SP-4", "Core Image compose throughput (faster than realtime?)"),
        ("SP-5", "CGEvent.location → source pixel mapping (Retina)"),
        ("SP-6", "Rounded-rect + gradient filter availability"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reel — Spike Harness").font(.title2.bold())
            Text("BUILD_PLAN §10 — run each before trusting the assumption in production code.")
                .font(.caption).foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8)], spacing: 8) {
                ForEach(spikes, id: \.id) { spike in
                    Button { run(spike.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spike.id).font(.caption.bold()).foregroundStyle(.tint)
                            Text(spike.title).font(.caption).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .disabled(log.running)
                }
            }

            HStack {
                Button("Clear log") { log.clear() }
                if log.running { ProgressView().controlSize(.small) }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
    }

    private func run(_ id: String) {
        log.running = true
        Task {
            defer { Task { @MainActor in log.running = false } }
            switch id {
            case "SP-0": await Spikes.captureToRawMovie(log: log)
            case "SP-1": await Spikes.audioTracks(log: log)
            case "SP-2": await Spikes.eventTapNoGrant(log: log)
            case "SP-3": await Spikes.clockSync(log: log)
            case "SP-4": await Spikes.compositeThroughput(log: log)
            case "SP-5": await Spikes.coordinateMapping(log: log)
            case "SP-6": await Spikes.filterAvailability(log: log)
            default: break
            }
        }
    }
}
