import Carbon.HIToolbox
import Foundation

/// User preferences (Darkroom Settings, IMPLEMENTATION_BRIEF §2.6). UserDefaults-backed; every
/// key read through here so defaults live in one place.
enum AppSettings {
    private static let d = UserDefaults.standard

    // RECORDING
    static var countdownSeconds: Int {                    // 0 off · 3 · 10 (default 3)
        get { d.object(forKey: "countdown") as? Int ?? 3 }
        set { d.set(newValue, forKey: "countdown") }
    }
    static var hideDesktopWhileRecording: Bool {
        get { d.object(forKey: "hideDesktop") as? Bool ?? true }
        set { d.set(newValue, forKey: "hideDesktop") }
    }
    /// Start/stop hotkey (default ⌘⇧R).
    static var hotkeyKeyCode: UInt32 {
        get { d.object(forKey: "hotkeyCode") as? UInt32 ?? UInt32(kVK_ANSI_R) }
        set { d.set(newValue, forKey: "hotkeyCode") }
    }
    static var hotkeyModifiers: UInt32 {                  // Carbon modifier mask
        get { d.object(forKey: "hotkeyMods") as? UInt32 ?? UInt32(cmdKey | shiftKey) }
        set { d.set(newValue, forKey: "hotkeyMods") }
    }
    static var hotkeyLabelKeys: [String] {
        var keys: [String] = []
        let m = hotkeyModifiers
        if m & UInt32(cmdKey) != 0 { keys.append("⌘") }
        if m & UInt32(shiftKey) != 0 { keys.append("⇧") }
        if m & UInt32(optionKey) != 0 { keys.append("⌥") }
        if m & UInt32(controlKey) != 0 { keys.append("⌃") }
        keys.append(keyName(for: hotkeyKeyCode))
        return keys
    }

    // DEFAULTS
    static var defaultBackgroundIndex: Int {
        get { d.object(forKey: "defaultBackground") as? Int ?? 0 }
        set { d.set(newValue, forKey: "defaultBackground") }
    }
    static var copyToClipboardAfterExport: Bool {
        get { d.object(forKey: "settings.copyAfterExport") as? Bool ?? true }
        set { d.set(newValue, forKey: "settings.copyAfterExport") }
    }

    // LICENSE (UI + local storage only until the merchant-of-record account exists — OT-4).
    static var licenseKey: String? {
        get { d.string(forKey: "licenseKey") }
        set { d.set(newValue, forKey: "licenseKey") }
    }
    static var isLicensed: Bool { licenseKey != nil }

    /// Floating pill position (persisted across takes).
    static var pillOrigin: CGPoint? {
        get {
            guard let a = d.array(forKey: "pillOrigin") as? [Double], a.count == 2 else { return nil }
            return CGPoint(x: a[0], y: a[1])
        }
        set {
            if let p = newValue { d.set([p.x, p.y], forKey: "pillOrigin") }
            else { d.removeObject(forKey: "pillOrigin") }
        }
    }

    static func keyName(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A...kVK_ANSI_Z where letterMap[Int(code)] != nil: return letterMap[Int(code)]!
        default: return letterMap[Int(code)] ?? "?"
        }
    }

    /// Carbon virtual keycodes are not alphabetical; map the common ones.
    private static let letterMap: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9", kVK_Space: "Space", kVK_Return: "↩",
    ]
}
