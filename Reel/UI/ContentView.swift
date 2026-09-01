import ScreenCaptureKit
import SwiftUI

/// The Darkroom launcher (IMPLEMENTATION_BRIEF §2.1/§2.2, artboards 1a/1b).
/// 800×~620 fixed, hidden titlebar, one decision: what to record.
struct ContentView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var displays: [SCDisplay] = []
    @State private var windows: [SCWindow] = []
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var selectedWindowID: CGWindowID?
    @State private var sourceKind: SourceKind = .display
    @State private var recents: [RecentRecording] = []
    private let areaPicker = AreaPickerController()

    enum SourceKind: String, CaseIterable {
        case display = "Display", window = "Window", area = "Area"
    }

    var body: some View {
        VStack(spacing: 0) {
            brandRow
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    hero
                    bodyContent
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 20)
            }
            footer
        }
        .background(RC.base)
        .frame(width: 800, height: 640)
        .task { await coordinator.checkAccess(); await refreshSources(); refreshRecents() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await coordinator.checkAccess(); await refreshSources() }
                refreshRecents()
            }
        }
        .onChange(of: coordinator.phase) { _, _ in refreshRecents() }
    }

    // MARK: Brand row (§2.1.1)

    private var brandRow: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(RC.amber).frame(width: 26, height: 26)
                Circle().fill(RC.base).frame(width: 9, height: 9)
            }
            Text("Reel").font(.system(size: 13, weight: .semibold)).foregroundStyle(RC.ink)
            Spacer()
            Text("v2.0").font(RC.mono(11)).foregroundStyle(RC.ink4)
        }
        .padding(.leading, 78)   // clear the traffic lights (hidden title bar)
        .padding(.trailing, 24)
        .frame(height: 48)
    }

    // MARK: Hero (§2.1.2)

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Record once. Ship a cinematic cut.")
                .font(RC.hero).tracking(-0.5)
                .foregroundStyle(RC.ink)
            Text("Zooms to every click, smooths the cursor, trims the dead air — edited before you press stop.")
                .font(.system(size: 13)).foregroundStyle(RC.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: Body

    @ViewBuilder
    private var bodyContent: some View {
        if coordinator.phase == .recording {
            recordingNote
        } else if !coordinator.hasAccess {
            PermissionCard()
        } else {
            sourcePicker
            if sourceKind == .window { windowPicker }
            recordButton
            statusStrip
            if !recents.isEmpty { recentsSection }
        }
    }

    /// The pill owns the live take (§2.3) — the launcher just says so if it's still visible.
    private var recordingNote: some View {
        HStack(spacing: 10) {
            PulsingDot(size: 10)
            Text("Recording — use the pill or \(AppSettings.hotkeyLabelKeys.joined()) to stop.")
                .font(RC.body).foregroundStyle(RC.ink2)
        }
        .frame(maxWidth: .infinity)
        .darkCard()
    }

    // MARK: Source picker (§2.1.3)

    private var sourcePicker: some View {
        HStack(spacing: 12) {
            SourceCard(kind: .display, selected: sourceKind == .display) { sourceKind = .display }
            SourceCard(kind: .window, selected: sourceKind == .window) {
                sourceKind = .window
                Task { await refreshSources() }
            }
            SourceCard(kind: .area, selected: sourceKind == .area) { sourceKind = .area }
        }
    }

    private var windowPicker: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(windows, id: \.windowID) { w in
                    Button {
                        selectedWindowID = w.windowID
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 12)).foregroundStyle(RC.ink3)
                            Text(windowTitle(w))
                                .font(.system(size: 12.5)).foregroundStyle(RC.ink)
                                .lineLimit(1)
                            Spacer()
                            if selectedWindowID == w.windowID {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(RC.amber)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(selectedWindowID == w.windowID ? RC.amberWash : RC.raised,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedWindowID == w.windowID ? RC.amberBorder : RC.hairline, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 150)
    }

    private func windowTitle(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "App"
        let title = w.title?.isEmpty == false ? w.title! : "Untitled"
        return "\(app) — \(title)"
    }

    // MARK: Record button (§2.1.4 — ink fill, NOT amber)

    private var recordButton: some View {
        Button {
            startFlow()
        } label: {
            HStack(spacing: 11) {
                Circle().fill(RC.live).frame(width: 11, height: 11)
                Text("Start Recording")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RC.base)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(AppSettings.hotkeyLabelKeys, id: \.self) { Keycap(text: $0) }
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(RC.ink, in: RoundedRectangle(cornerRadius: RC.rHero))
            .contentShape(RoundedRectangle(cornerRadius: RC.rHero))
        }
        .buttonStyle(.plain)
        .hoverRaise(-2)
        .disabled(!canStart)
        .opacity(canStart ? 1 : 0.5)
    }

    private var canStart: Bool {
        switch sourceKind {
        case .display: return selectedDisplay != nil
        case .window: return selectedWindow != nil
        case .area: return selectedDisplay != nil
        }
    }

    private func startFlow() {
        switch sourceKind {
        case .display:
            guard let d = selectedDisplay else { return }
            coordinator.beginRecordingFlow(source: .display(d))
        case .window:
            guard let w = selectedWindow else { return }
            coordinator.beginRecordingFlow(source: .window(w))
        case .area:
            guard let d = selectedDisplay, let screen = NSScreen.main else { return }
            areaPicker.pick(on: screen) { rect in
                guard let rect else { return }
                coordinator.beginRecordingFlow(source: .area(d, rect))
            }
        }
    }

    // MARK: Status strip (processing / failed / ready-to-edit)

    @ViewBuilder
    private var statusStrip: some View {
        switch coordinator.phase {
        case let .processing(msg):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(msg).font(RC.body).foregroundStyle(RC.ink2)
            }
        case let .failed(msg):
            Text(msg).font(RC.body).foregroundStyle(RC.live).multilineTextAlignment(.center)
        default:
            EmptyView()
        }
    }

    // MARK: Recents (§2.1.5)

    struct RecentRecording: Identifiable {
        var id: URL { url }
        let url: URL
        let date: Date
        let duration: Double
        let sizeBytes: Int
        let thumbnail: NSImage?
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaps(text: "Recent")
            VStack(spacing: 2) {
                ForEach(recents.prefix(4)) { rec in RecentRow(rec: rec, openAction: {
                    openWindow(value: rec.url)
                }, deleteAction: {
                    try? FileManager.default.trashItem(at: rec.url, resultingItemURL: nil)
                    refreshRecents()
                }) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("records locally · no account · yours to keep")
                .font(.system(size: 11)).foregroundStyle(RC.ink4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
    }

    // MARK: Data

    private var selectedDisplay: SCDisplay? {
        displays.first { $0.displayID == selectedDisplayID } ?? displays.first
    }
    private var selectedWindow: SCWindow? {
        windows.first { $0.windowID == selectedWindowID }
    }

    private func refreshSources() async {
        guard coordinator.hasAccess else { return }
        displays = (try? await ShareableContent.displays()) ?? []
        if selectedDisplayID == nil { selectedDisplayID = displays.first?.displayID }
        if sourceKind == .window,
           let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
            windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                    && $0.frame.width > 200 && $0.frame.height > 150
                    && ($0.title?.isEmpty == false || $0.owningApplication != nil)
            }
        }
    }

    private func refreshRecents() {
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            recents = []; return
        }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: movies, includingPropertiesForKeys:
            [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        recents = items
            .filter { $0.pathExtension == "reelproj" }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
            .compactMap { url -> RecentRecording? in
                guard let data = try? Data(contentsOf: url.appendingPathComponent("project.json")),
                      let project = try? JSONDecoder().decode(ReelProject.self, from: data) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rawAttrs = try? fm.attributesOfItem(atPath: url.appendingPathComponent("raw.mov").path)
                let size = (rawAttrs?[.size] as? Int) ?? 0
                let thumb = NSImage(contentsOf: url.appendingPathComponent("thumbnail.png"))
                return RecentRecording(url: url, date: date, duration: project.duration,
                                       sizeBytes: size, thumbnail: thumb)
            }
            .sorted { $0.date > $1.date }
        // Backfill thumbnails for takes recorded before thumbnails existed.
        for rec in recents.prefix(4) where rec.thumbnail == nil {
            Task.detached {
                RecordingCoordinator.writeThumbnail(for: rec.url)
                await MainActor.run { refreshRecents2() }
            }
        }
    }

    /// Thumbnail backfill completion hop (avoids capturing self-mutating state in the task).
    private func refreshRecents2() { refreshRecents() }
}

// MARK: - Source card (§2.1.3)

private struct SourceCard: View {
    let kind: ContentView.SourceKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                icon
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? RC.amber : RC.ink3)
                Text(kind.rawValue)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected ? RC.ink : RC.ink2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(RC.raised, in: RoundedRectangle(cornerRadius: RC.rCard))
            .overlay(RoundedRectangle(cornerRadius: RC.rCard)
                .stroke(selected ? RC.amber : (hovering ? Color.white.opacity(0.20) : RC.hairline),
                        lineWidth: selected ? 1.5 : 1))
            .overlay(selected
                ? RoundedRectangle(cornerRadius: RC.rCard).stroke(RC.amberWash, lineWidth: 3).padding(-2)
                : nil)
            .contentShape(RoundedRectangle(cornerRadius: RC.rCard))
        }
        .buttonStyle(.plain)
        .hoverRaise()
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .display: Image(systemName: "display")
        case .window: Image(systemName: "macwindow")
        case .area: Image(systemName: "viewfinder")
        }
    }
}

// MARK: - Recent row (§2.1.5)

private struct RecentRow: View {
    let rec: ContentView.RecentRecording
    let openAction: () -> Void
    let deleteAction: () -> Void
    @State private var hovering = false
    @State private var deleteHover = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb = rec.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [RC.raised, RC.stage],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: 76, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: RC.rChip))

            VStack(alignment: .leading, spacing: 2) {
                Text(rec.url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(RC.ink)
                Text(meta).font(RC.mono(11)).foregroundStyle(RC.ink3)
            }
            Spacer()
            HStack(spacing: 16) {
                actionText("Open", color: RC.ink3, hoverColor: RC.amber, action: openAction)
                actionText("Reveal", color: RC.ink3, hoverColor: RC.amber) {
                    NSWorkspace.shared.activateFileViewerSelecting([rec.url])
                }
                actionText("Delete", color: RC.ink3, hoverColor: RC.live, action: deleteAction)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovering ? RC.raised : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { openAction() }
    }

    private var meta: String {
        let s = Int(rec.duration.rounded())
        let dur = String(format: "%d:%02d", s / 60, s % 60)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let ago = f.localizedString(for: rec.date, relativeTo: Date())
        let mb = rec.sizeBytes / 1_000_000
        return "\(dur) · \(ago) · \(mb) MB"
    }

    private func actionText(_ label: String, color: Color, hoverColor: Color,
                            action: @escaping () -> Void) -> some View {
        ActionText(label: label, color: color, hoverColor: hoverColor, action: action)
    }
}

private struct ActionText: View {
    let label: String
    let color: Color
    let hoverColor: Color
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 11.5))
                .foregroundStyle(hovering ? hoverColor : color)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Permission card (§2.2, artboard 1b)

struct PermissionCard: View {
    @State private var screenGranted = CapturePermissions.hasScreenRecordingAccess
    @State private var axGranted = ElementResolver.isTrusted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Before your first take").font(RC.title).foregroundStyle(RC.ink)
                Text("macOS asks for two permissions. Both are read on this Mac only — nothing is sent anywhere.")
                    .font(.system(size: 12.5)).foregroundStyle(RC.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(icon: "rectangle.dashed.badge.record",
                          name: "Screen Recording",
                          reason: "So Reel can capture your display",
                          granted: screenGranted) {
                CapturePermissions.requestScreenRecordingAccess()
                CapturePermissions.openScreenRecordingSettings()
            }
            permissionRow(icon: "cursorarrow.motionlines",
                          name: "Accessibility",
                          reason: "Reads clicks — so the camera knows where to zoom",
                          granted: axGranted) {
                ElementResolver.requestTrust()
            }

            Text("You can change either anytime in System Settings. Reel never records until you do.")
                .font(.system(size: 11)).foregroundStyle(RC.ink4)

            if screenGranted {
                Button { CapturePermissions.relaunchApp() } label: {
                    Label("Relaunch Reel", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.reelInk)
            }
        }
        .onReceive(timer) { _ in
            screenGranted = CapturePermissions.hasScreenRecordingAccess
            axGranted = ElementResolver.isTrusted
        }
    }

    private func permissionRow(icon: String, name: String, reason: String, granted: Bool,
                               grantAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(granted ? RC.amberWash : Color.white.opacity(0.06))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(granted ? RC.amber : RC.ink3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(RC.ink)
                Text(reason).font(.system(size: 11.5)).foregroundStyle(RC.ink3)
            }
            Spacer()
            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text("Granted").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(RC.amber)
            } else {
                Button("Grant…") { grantAction() }.buttonStyle(.reelInk)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RC.raised, in: RoundedRectangle(cornerRadius: RC.rCard))
        .overlay(RoundedRectangle(cornerRadius: RC.rCard).stroke(RC.hairline, lineWidth: 1))
    }
}
