import Carbon.HIToolbox
import Foundation

/// Global start/stop hotkey (LAUNCH_PLAN P1.3) via Carbon RegisterEventHotKey — no dependencies,
/// works without Accessibility for REGISTERED combos. One hotkey today; re-registered when the
/// user records a new combo in Settings (§2.6).
final class HotKeys {
    static let shared = HotKeys()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onToggle: (() -> Void)?

    private init() {}

    func register(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.onToggle?() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5245454C) /* 'REEL' */, id: 1)
        RegisterEventHotKey(AppSettings.hotkeyKeyCode, AppSettings.hotkeyModifiers,
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func reregister() {
        guard let onToggle else { return }
        register(onToggle: onToggle)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }
}
