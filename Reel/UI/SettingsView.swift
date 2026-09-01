import Carbon.HIToolbox
import SwiftUI

/// Settings (IMPLEMENTATION_BRIEF §2.6, artboard 1f) — one pane, no nagging.
struct SettingsView: View {
    @State private var countdown = AppSettings.countdownSeconds
    @State private var hideDesktop = AppSettings.hideDesktopWhileRecording
    @State private var copyAfterExport = AppSettings.copyToClipboardAfterExport
    @State private var defaultBG = AppSettings.defaultBackgroundIndex
    @State private var licenseField = ""
    @State private var licensed = AppSettings.isLicensed
    @State private var recordingHotkey = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group("Recording") {
                    row("Countdown") {
                        HStack(spacing: 6) {
                            ForEach([0, 3, 10], id: \.self) { s in
                                Chip(text: s == 0 ? "Off" : "\(s)s", selected: countdown == s, height: 26) {
                                    countdown = s
                                    AppSettings.countdownSeconds = s
                                }
                            }
                        }
                    }
                    divider
                    row("Start / stop shortcut") {
                        Button {
                            recordingHotkey = true
                        } label: {
                            HStack(spacing: 4) {
                                if recordingHotkey {
                                    Text("press keys…").font(RC.mono(11)).foregroundStyle(RC.amber)
                                } else {
                                    ForEach(AppSettings.hotkeyLabelKeys, id: \.self) { k in
                                        Keycap(text: k, size: 12)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .background(HotkeyRecorder(active: $recordingHotkey))
                    }
                    divider
                    toggleRow("Hide desktop while recording",
                              sub: "Icons and wallpaper clutter never make the cut",
                              isOn: $hideDesktop) { AppSettings.hideDesktopWhileRecording = $0 }
                }

                group("Defaults") {
                    row("Background") {
                        HStack(spacing: 6) {
                            ForEach(Array(ThemePresets.all.prefix(4).enumerated()), id: \.offset) { i, preset in
                                BackgroundSwatch(style: preset.background, selected: defaultBG == i) {
                                    defaultBG = i
                                    AppSettings.defaultBackgroundIndex = i
                                }
                            }
                        }
                    }
                    divider
                    toggleRow("Copy to clipboard after export", sub: nil, isOn: $copyAfterExport) {
                        AppSettings.copyToClipboardAfterExport = $0
                    }
                }

                group("License") {
                    if licensed {
                        row("Licensed") {
                            HStack(spacing: 10) {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                    Text("Active").font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(RC.amber)
                                Button("Deactivate") {
                                    AppSettings.licenseKey = nil
                                    licensed = false
                                }
                                .buttonStyle(.reelSecondary)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                TextField("REEL-XXXX-XXXX-XXXX", text: $licenseField)
                                    .textFieldStyle(.plain)
                                    .font(RC.mono(12))
                                    .foregroundStyle(RC.ink)
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                                    .background(RC.field, in: RoundedRectangle(cornerRadius: RC.rButton))
                                    .overlay(RoundedRectangle(cornerRadius: RC.rButton)
                                        .stroke(RC.hairline, lineWidth: 1))
                                Button("Activate") { activate() }
                                    .buttonStyle(InkButtonStyle(height: 36, fontSize: 12.5))
                            }
                            Text("Trial adds a small watermark — everything else works, forever. One purchase, this Mac and your next one.")
                                .font(.system(size: 11)).foregroundStyle(RC.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16)
                    }
                }
            }
            .padding(24)
        }
        .background(RC.base)
        .frame(width: 680, height: 520)
    }

    private func activate() {
        // Format-validated locally; real activation lands with the merchant account (OT-4 —
        // the Licensing protocol swaps in behind this same field).
        let key = licenseField.trimmingCharacters(in: .whitespaces).uppercased()
        guard key.hasPrefix("REEL-"), key.count >= 19 else { return }
        AppSettings.licenseKey = key
        licensed = true
    }

    private var divider: some View {
        Rectangle().fill(RC.hairlineSoft).frame(height: 1).padding(.leading, 16)
    }

    private func group(_ name: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaps(text: name)
            VStack(spacing: 0) { content() }
                .background(RC.raised, in: RoundedRectangle(cornerRadius: RC.rCard))
                .overlay(RoundedRectangle(cornerRadius: RC.rCard).stroke(RC.hairline, lineWidth: 1))
        }
    }

    private func row(_ name: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(name).font(RC.body).foregroundStyle(RC.ink)
            Spacer()
            control()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }

    private func toggleRow(_ name: String, sub: String?, isOn: Binding<Bool>,
                           save: @escaping (Bool) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(RC.body).foregroundStyle(RC.ink)
                if let sub {
                    Text(sub).font(.system(size: 11)).foregroundStyle(RC.ink3)
                }
            }
            Spacer()
            ReelToggle(isOn: Binding(get: { isOn.wrappedValue },
                                     set: { isOn.wrappedValue = $0; save($0) }))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Invisible key-capture layer for the shortcut recorder (§2.6 "click-to-record new hotkey").
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var active: Bool

    func makeNSView(context: Context) -> RecorderNSView {
        let v = RecorderNSView()
        v.onCapture = { code, mods in
            AppSettings.hotkeyKeyCode = code
            AppSettings.hotkeyModifiers = mods
            HotKeys.shared.reregister()
            active = false
        }
        return v
    }

    func updateNSView(_ v: RecorderNSView, context: Context) {
        v.isActive = active
        if active { DispatchQueue.main.async { v.window?.makeFirstResponder(v) } }
    }

    final class RecorderNSView: NSView {
        var onCapture: ((UInt32, UInt32) -> Void)?
        var isActive = false
        override var acceptsFirstResponder: Bool { isActive }
        override func keyDown(with event: NSEvent) {
            guard isActive else { super.keyDown(with: event); return }
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            guard mods != 0 else { return }   // require at least one modifier
            onCapture?(UInt32(event.keyCode), mods)
        }
    }
}
