import SwiftUI

/// The export sheet (IMPLEMENTATION_BRIEF §2.5, artboard 1e): configure → rendering → the payoff.
struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settings.copyAfterExport") private var copyAfterExport = true
    @State private var didAutoCopy = false

    var body: some View {
        VStack(spacing: 0) {
            if model.exportedURL != nil {
                doneState
            } else if model.isExporting {
                renderingState
            } else {
                configureState
            }
        }
        .padding(24)
        .frame(width: 388)
        .background(RC.raised)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.easeOut(duration: 0.2), value: model.isExporting)
        .animation(.easeOut(duration: 0.2), value: model.exportedURL)
        .onDisappear { model.exportedURL = nil; model.exportProgress = 0 }
    }

    // MARK: State A — configure

    private var configureState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(RC.panelTitle).foregroundStyle(RC.ink)

            chipGroup("Format", items: EditorModel.ExportFormat.allCases.map(\.rawValue),
                      selected: model.exportFormat.rawValue) { picked in
                model.exportFormat = EditorModel.ExportFormat.allCases.first { $0.rawValue == picked } ?? .mp4
                if model.exportFormat == .gif {
                    model.exportFPS = 30
                    if model.exportResolution == .r4k { model.exportResolution = .r1080 }
                }
            }
            chipGroup("Resolution", items: EditorModel.ExportResolution.allCases.map(\.rawValue),
                      selected: model.exportResolution.rawValue,
                      disabled: model.exportFormat == .gif ? ["4K", "1440p"] : []) { picked in
                model.exportResolution = EditorModel.ExportResolution.allCases.first { $0.rawValue == picked } ?? .r1440
            }
            chipGroup("Frame rate", items: ["30", "60"], selected: "\(model.exportFPS)",
                      disabled: model.exportFormat == .gif ? ["60"] : []) { picked in
                model.exportFPS = Int(picked) ?? 60
            }

            Rectangle().fill(RC.hairlineSoft).frame(height: 1)

            HStack {
                Text(model.exportDurationLabel).font(RC.mono(11)).foregroundStyle(RC.ink3)
                Spacer()
                Text(model.exportEstimate).font(RC.mono(11)).foregroundStyle(RC.ink3)
            }

            Button("Export Video") {
                didAutoCopy = false
                Task { await model.export()
                       if copyAfterExport, model.exportedURL != nil {
                           model.copyExportToClipboard(); didAutoCopy = true
                       } }
            }
            .buttonStyle(.reelPrimaryLarge)
            .frame(maxWidth: .infinity)
        }
    }

    private func chipGroup(_ name: String, items: [String], selected: String,
                           disabled: [String] = [], pick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionCaps(text: name, size: 10.5)
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Chip(text: item, selected: item == selected, height: 30) { pick(item) }
                        .disabled(disabled.contains(item))
                        .opacity(disabled.contains(item) ? 0.45 : 1)
                }
            }
        }
    }

    // MARK: State B — rendering

    private var renderingState: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(RC.stage)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: 200)
            HStack {
                Text("Rendering zooms…").font(.system(size: 13, weight: .semibold)).foregroundStyle(RC.ink)
                Spacer()
                Text(etaLabel).font(RC.mono(11)).foregroundStyle(RC.ink3)
            }
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.09)).frame(height: 6)
                        Capsule().fill(RC.amber)
                            .frame(width: max(4, geo.size.width * model.exportProgress), height: 6)
                    }
                }
                .frame(height: 6)
                Text("\(Int(model.exportProgress * 100))%").font(RC.mono(11)).foregroundStyle(RC.amber)
            }
            Button("Cancel") { dismiss() }.buttonStyle(.reelQuiet)
        }
        .padding(.vertical, 8)
    }

    private var etaLabel: String {
        guard model.exportProgress > 0.03 else { return "…" }
        // Rough: assume linear progress over the edited duration.
        let remaining = model.editedDuration * (1 - model.exportProgress) * 0.4
        return String(format: "%d:%02d left", Int(remaining) / 60, Int(remaining) % 60)
    }

    // MARK: State C — done, the payoff (§2.5)

    @State private var popped = false

    private var doneState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(RC.amberWash).frame(width: 58, height: 58)
                    .overlay(Circle().stroke(RC.amber, lineWidth: 1.5))
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(RC.amber)
            }
            .scaleEffect(popped ? 1 : 0.5)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { popped = true }
            }

            Text("Ready to ship").font(RC.panelTitle).foregroundStyle(RC.ink)
            Text(fileMeta).font(RC.mono(11)).foregroundStyle(RC.ink3)

            VStack(spacing: 8) {
                Button(didAutoCopy ? "Copied — Copy Again" : "Copy to Clipboard") {
                    model.copyExportToClipboard()
                }
                .buttonStyle(PrimaryButtonStyle(height: 40))
                .frame(maxWidth: .infinity)
                Button("Reveal in Finder") { model.revealExport() }
                    .buttonStyle(SecondaryButtonStyle(height: 40))
                    .frame(maxWidth: .infinity)
            }
            Text("Saved to Movies / Reel — drag the thumbnail anywhere")
                .font(.system(size: 10.5)).foregroundStyle(RC.ink4)
        }
        .padding(.vertical, 8)
    }

    private var fileMeta: String {
        guard let url = model.exportedURL else { return "" }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let mb = size.map { "\($0 / 1_000_000) MB" } ?? ""
        let dur = max(0, model.editedDuration - model.silenceSavings)
        let d = String(format: "%d:%02d", Int(dur) / 60, Int(dur) % 60)
        return "\(url.lastPathComponent) · \(d) · \(mb)"
    }
}
