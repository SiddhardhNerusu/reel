import ScreenCaptureKit
import SwiftUI

/// The Launch screen (BUILD_PLAN §7 onboarding + §11 M1): pick a source, record in one decision.
/// Deliberately calm — one primary action, everything else quiet.
struct ContentView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var displays: [SCDisplay] = []
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var editorDoc: ReelDocument?
    @State private var sourceKind: SourceKind = .display

    enum SourceKind: String, CaseIterable { case display = "Display", window = "Window" }

    var body: some View {
        ZStack {
            WindowBackground()
            VStack(spacing: 0) {
                topBar
                VStack(spacing: 22) {
                    hero
                    bodyContent
                }
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // center vertically
                .padding(.horizontal, 28)
            }
        }
        .frame(minWidth: 640, minHeight: 580)
        .task { await coordinator.checkAccess(); await refreshDisplays() }
        .onChange(of: scenePhase) { _, phase in
            // Returning from System Settings after enabling access — re-check without a relaunch.
            if phase == .active {
                Task { await coordinator.checkAccess(); await refreshDisplays() }
            }
        }
        .sheet(item: $editorDoc) { doc in
            EditorView(model: EditorModel(doc: doc))
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 9) {
            Circle().fill(RC.record).frame(width: 10, height: 10)
                .shadow(color: RC.record.opacity(0.5), radius: 4)
            Text("Reel").font(.system(size: 15, weight: .bold)).foregroundStyle(RC.text)
            Spacer()
        }
        .padding(.leading, 78)   // clear the traffic lights (hidden title bar)
        .padding(.trailing, 20)
        .frame(height: 46)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 8) {
            Text("Record a demo worth shipping")
                .font(.system(size: 26, weight: .bold)).tracking(-0.3)
                .foregroundStyle(RC.text).multilineTextAlignment(.center)
            Text("Reel films your screen and auto-edits the camera — zoom, pan, and a smooth cursor — while you just click.")
                .font(.system(size: 14)).foregroundStyle(RC.textDim)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    // MARK: Body (permission / capture / status)

    @ViewBuilder
    private var bodyContent: some View {
        if coordinator.phase == .recording {
            recordingBar
        } else if !coordinator.hasAccess {
            permissionCard
            sampleRow
        } else {
            sourcePicker
            captureCTAs
            trustLine
        }
        statusStrip
    }

    private var sourcePicker: some View {
        VStack(spacing: 14) {
            SegPicker(selection: $sourceKind)

            if sourceKind == .display {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(Array(displays.enumerated()), id: \.element.displayID) { i, d in
                        SourceCard(
                            title: displayName(i),
                            subtitle: "\(d.width) × \(d.height)",
                            gradientIndex: i,
                            selected: d.displayID == selectedDisplayID
                        ) { selectedDisplayID = d.displayID }
                    }
                }
            } else {
                Text("Window recording arrives in a later build — record a full display for now.")
                    .font(.system(size: 13)).foregroundStyle(RC.textFaint)
                    .multilineTextAlignment(.center).padding(.vertical, 18)
            }
        }
    }

    private var captureCTAs: some View {
        HStack(spacing: 12) {
            Button {
                guard let d = selectedDisplay else { return }
                Task { await coordinator.startRecording(display: d) }
            } label: {
                Label("Start Recording", systemImage: "record.circle.fill")
            }
            .buttonStyle(.reelRecord)
            .disabled(sourceKind == .window || selectedDisplay == nil)

            Button("Try a sample") { Task { await coordinator.renderSampleDemo() } }
                .buttonStyle(.reelGhostLarge)
        }
    }

    private var trustLine: some View {
        HStack(spacing: 18) {
            ForEach(["Records locally", "No account", "Yours to keep"], id: \.self) { t in
                HStack(spacing: 6) {
                    Circle().fill(RC.textFaint).frame(width: 4, height: 4)
                    Text(t).font(.system(size: 12.5)).foregroundStyle(RC.textFaint)
                }
            }
        }
        .padding(.top, 2)
    }

    private var sampleRow: some View {
        Button("Try a sample instead") { Task { await coordinator.renderSampleDemo() } }
            .buttonStyle(.reelGhostLarge)
    }

    // MARK: Permission

    private var permissionCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [RC.accent, RC.accent.opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 58, height: 58)
                    .shadow(color: RC.accent.opacity(0.45), radius: 16, y: 7)
                Image(systemName: "lock.shield.fill").font(.system(size: 27, weight: .medium)).foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("One quick permission").font(.system(size: 17, weight: .bold)).foregroundStyle(RC.text)
                Text("macOS needs your OK for Reel to see the screen — the only permission we ask for. Nothing leaves your Mac.")
                    .font(.system(size: 13)).foregroundStyle(RC.textDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 350)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                permissionStep(1, "Open Screen Recording settings")
                permissionStep(2, "Turn on Reel, then relaunch")
            }
            .frame(maxWidth: 320)

            HStack(spacing: 10) {
                Button {
                    _ = CapturePermissions.requestScreenRecordingAccess()
                    CapturePermissions.openScreenRecordingSettings()
                } label: { Label("Open settings", systemImage: "arrow.up.forward.app.fill") }
                .buttonStyle(.reelAccent)

                Button { CapturePermissions.relaunchApp() } label: {
                    Label("I've enabled it", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.reelSoft)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .reelCard(padding: 30)
    }

    private func permissionStep(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(RC.accent)
                .frame(width: 20, height: 20)
                .background(RC.accent.opacity(0.16), in: Circle())
            Text(text).font(.system(size: 12.5)).foregroundStyle(RC.textDim)
            Spacer(minLength: 0)
        }
    }

    // MARK: Recording / status

    private var recordingBar: some View {
        HStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                HStack(spacing: 9) {
                    Circle().fill(coordinator.isPaused ? RC.textFaint : RC.record).frame(width: 10, height: 10)
                        .opacity(coordinator.isPaused ? 1 : (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.4))
                    Text("\(coordinator.isPaused ? "Paused" : "Recording") · \(elapsed(context.date))")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(RC.text)
                }
            }
            Button { coordinator.togglePause() } label: {
                Image(systemName: coordinator.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.reelSoft)
            Button { Task { await coordinator.stopRecording() } } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.reelSoft)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RC.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RC.hairlineStrong, lineWidth: 1))
    }

    @ViewBuilder
    private var statusStrip: some View {
        switch coordinator.phase {
        case let .processing(msg):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(msg).font(.system(size: 13)).foregroundStyle(RC.textDim)
                if coordinator.exportProgress > 0 {
                    ProgressView(value: coordinator.exportProgress).frame(width: 120)
                }
            }
            .padding(.top, 4)
        case let .ready(url):
            resultCard(url: url)
        case let .failed(msg):
            Text(msg).font(.system(size: 13)).foregroundStyle(RC.record)
                .multilineTextAlignment(.center).padding(.top, 4)
        default:
            if let doc = coordinator.lastProject {
                readyToEdit(doc)
            }
        }
    }

    private func resultCard(url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(RC.success)
            VStack(alignment: .leading, spacing: 1) {
                Text("Exported").font(.system(size: 13, weight: .semibold)).foregroundStyle(RC.text)
                Text(url.lastPathComponent).font(.system(size: 11.5)).foregroundStyle(RC.textFaint)
            }
            Spacer()
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.reelSoft)
            if let doc = coordinator.lastProject {
                Button("Open editor") { editorDoc = doc }.buttonStyle(.reelAccent)
            }
        }
        .reelCard(padding: 14)
    }

    private func readyToEdit(_ doc: ReelDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars").foregroundStyle(RC.accent)
            Text("Recording ready to polish").font(.system(size: 13, weight: .semibold)).foregroundStyle(RC.text)
            Spacer()
            Button("Open editor") { editorDoc = doc }.buttonStyle(.reelAccent)
        }
        .reelCard(padding: 14)
    }

    // MARK: Helpers

    private var selectedDisplay: SCDisplay? { displays.first { $0.displayID == selectedDisplayID } }

    private func displayName(_ i: Int) -> String {
        displays.count == 1 ? "Main Display" : "Display \(i + 1)"
    }

    private func elapsed(_ now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(coordinator.recordingStartedAt ?? now)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func refreshDisplays() async {
        guard coordinator.hasAccess else { return }
        displays = (try? await ShareableContent.displays()) ?? []
        if selectedDisplayID == nil { selectedDisplayID = displays.first?.displayID }
    }
}

// MARK: - Components

private struct SegPicker: View {
    @Binding var selection: ContentView.SourceKind
    var body: some View {
        HStack(spacing: 2) {
            ForEach(ContentView.SourceKind.allCases, id: \.self) { kind in
                Button { selection = kind } label: {
                    Text(kind.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection == kind ? RC.text : RC.textDim)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(selection == kind ? RC.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .shadow(color: selection == kind ? .black.opacity(0.15) : .clear, radius: 3, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RC.surface2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RC.hairline, lineWidth: 1))
    }
}

private struct SourceCard: View {
    let title: String
    let subtitle: String
    let gradientIndex: Int
    let selected: Bool
    let action: () -> Void

    private static let gradients: [[Color]] = [
        [Color(hex: 0x5B66FA), Color(hex: 0x9A57EB)],
        [Color(hex: 0xF5A15B), Color(hex: 0xE14F6E)],
        [Color(hex: 0x38CCAD), Color(hex: 0x33A0D9)],
        [Color(hex: 0x2A2B33), Color(hex: 0x3A3B47)],
    ]

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: Self.gradients[gradientIndex % Self.gradients.count],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.9))
                                .padding(.horizontal, 22).padding(.vertical, 18)
                        )
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, RC.accent).font(.system(size: 18))
                            .padding(8)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(RC.text)
                    Text(subtitle).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(RC.textFaint)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RC.surface2, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(selected ? RC.accent : RC.hairline, lineWidth: selected ? 1.5 : 1)
            )
            .overlay(
                selected ? RoundedRectangle(cornerRadius: 13).stroke(RC.accent.opacity(0.25), lineWidth: 4) : nil
            )
            .shadow(color: selected ? RC.accent.opacity(0.25) : .black.opacity(0.15), radius: selected ? 14 : 8, y: 5)
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}
