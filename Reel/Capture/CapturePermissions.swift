import AppKit
import AVFoundation
import CoreGraphics

/// TCC onboarding helpers (BUILD_PLAN §7).
///
/// Screen Recording is system-managed (no Info.plist key); after the FIRST grant the app
/// usually needs a relaunch before SCK delivers frames. macOS 15 also re-confirms the grant
/// monthly — that is OS behavior, not a bug; surface it kindly. TCC grants are bound to the
/// code-signing identity, so ship a stable Developer ID or every build resets the grant.
enum CapturePermissions {

    static var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Raises the system Screen Recording dialog if not yet granted.
    /// Returns true if access is already in place (no relaunch needed).
    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Relaunch the app — macOS only applies a fresh Screen Recording grant to a NEW process, so
    /// after the user enables it we offer a one-click restart instead of "quit and reopen yourself".
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
