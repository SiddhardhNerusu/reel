import ApplicationServices
import CoreGraphics

/// Resolves the UI element under a click via the Accessibility API, so the camera can frame the
/// actual thing you clicked instead of a blind box around the cursor (REVAMP_BRIEF §5.2).
///
/// Returns the element's bounds in **global, top-left points** — the SAME coordinate space as
/// `CGEvent.location`, so no flip is needed before mapping into source pixels. On-device + free;
/// needs the Accessibility TCC grant (without it, every call returns nil and we fall back to a
/// padded box around the point).
enum ElementResolver {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt for Accessibility access (shows the system dialog once).
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.25)   // never hang the caller on a slow AX server
        return el
    }()

    /// The clicked element's bounds in global top-left points, or nil if unavailable.
    static func elementRect(atGlobalPoint p: CGPoint) -> CGRect? {
        guard isTrusted else { return nil }
        var out: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &out) == .success,
              let start = out else { return nil }
        // The system-wide timeout does NOT carry over to the returned per-app elements — those
        // default to 6 s per call, and a hung target app (verified live 2026-09-01: it serialized
        // minutes of blocking on the resolve queue and froze stop()). Cap them too.
        AXUIElementSetMessagingTimeout(start, 0.25)
        // Prefer the deepest element that reports a frame; walk up a couple hops if it reports none.
        var element = start
        for _ in 0..<3 {
            if let rect = frame(of: element) { return rect }
            guard let up = parent(of: element) else { break }
            AXUIElementSetMessagingTimeout(up, 0.25)
            element = up
        }
        return nil
    }

    // MARK: AX helpers

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let posV = value(el, kAXPositionAttribute), let sizeV = value(el, kAXSizeAttribute),
              CFGetTypeID(posV) == AXValueGetTypeID(), CFGetTypeID(sizeV) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(posV as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeV as! AXValue, .cgSize, &size) else { return nil }
        let r = CGRect(origin: pos, size: size)
        return (r.width > 0 && r.height > 0) ? r : nil
    }

    private static func parent(of el: AXUIElement) -> AXUIElement? {
        guard let v = value(el, kAXParentAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (v as! AXUIElement)
    }

    private static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
}
