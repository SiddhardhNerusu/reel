import CoreGraphics
import ScreenCaptureKit

/// Thin wrapper over `SCShareableContent` target enumeration + filter construction (BUILD_PLAN §5.1).
enum ShareableContent {

    static func current() async throws -> SCShareableContent {
        // Excludes desktop widgets; on-screen windows only — the usual demo-capture set.
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func displays() async throws -> [SCDisplay] {
        try await current().displays
    }

    static func windows() async throws -> [SCWindow] {
        try await current().windows
    }

    /// Full-display capture (optionally excluding some windows, e.g. our own recorder UI).
    static func filter(for display: SCDisplay, excluding windows: [SCWindow] = []) -> SCContentFilter {
        SCContentFilter(display: display, excludingWindows: windows)
    }

    /// Single-window capture — the "Screen Studio" look.
    static func filter(forWindow window: SCWindow) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: window)
    }
}
