import AppKit
import SwiftUI

/// Menu-bar presence (IMPLEMENTATION_BRIEF §2.3) as a plain NSStatusItem — SwiftUI's
/// MenuBarExtra label never re-rendered on recording state and its window refused to open
/// (verified live 2026-09-01), so the menu bar is AppKit: deterministic icon updates via a
/// timer, native menu for the controls.
@MainActor
final class StatusItemController {
    private var item: NSStatusItem?
    private var timer: Timer?
    private weak var coordinator: RecordingCoordinator?

    func attach(_ coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Reel")
        item = it
        rebuildMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private var wasRecording = false

    private func refresh() {
        guard let coordinator, let button = item?.button else { return }
        let recording = coordinator.phase == .recording
        if recording {
            let s = Int(max(0, Date().timeIntervalSince(coordinator.recordingStartedAt ?? Date())))
            let text = String(format: " %d:%02d", s / 60, s % 60)
            let attr = NSMutableAttributedString(
                string: "●", attributes: [.foregroundColor: NSColor.systemRed,
                                          .font: NSFont.systemFont(ofSize: 10)])
            attr.append(NSAttributedString(
                string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                                           .foregroundColor: NSColor.labelColor,
                                           .baselineOffset: 0.5]))
            button.image = nil
            button.attributedTitle = attr
        } else if wasRecording || button.image == nil {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Reel")
        }
        if recording != wasRecording {
            wasRecording = recording
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        guard let coordinator else { return }
        let menu = NSMenu()
        let hotkey = AppSettings.hotkeyLabelKeys.joined()
        if coordinator.phase == .recording {
            let pause = NSMenuItem(title: coordinator.isPaused ? "Resume" : "Pause",
                                   action: #selector(pauseTapped), keyEquivalent: "")
            pause.target = self
            menu.addItem(pause)
            let stop = NSMenuItem(title: "Stop & Edit", action: #selector(stopTapped), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "\(hotkey) stops from anywhere", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        } else {
            let start = NSMenuItem(title: "Start Recording", action: #selector(startTapped), keyEquivalent: "")
            start.target = self
            menu.addItem(start)
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "\(hotkey) starts a take", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        item?.menu = menu
    }

    @objc private func pauseTapped() {
        coordinator?.togglePause()
        rebuildMenu()
    }

    @objc private func stopTapped() {
        Task { await coordinator?.stopRecording() }
    }

    @objc private func startTapped() {
        coordinator?.hotkeyToggle()
    }
}
