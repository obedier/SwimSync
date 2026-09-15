import AppKit
import SwiftUI

/// SwiftUI's `Window` scene does not reopen itself when the app is already
/// running and its window has been closed. That is exactly the auto-open path:
/// close the window with ⌘W, leave SwimSync running, plug the player in, and
/// `open -a` would otherwise activate an app with nothing on screen.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by ContentView once SwiftUI can hand us its window-opening action.
    static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { self.ensureWindow() }
    }

    /// Fired by LaunchServices when `open -a` targets an already-running app —
    /// i.e. every time the player is reconnected.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        ensureWindow()
        return true
    }

    /// Keep the app alive when the window is closed so the mount trigger has
    /// something to reopen, rather than paying a cold launch each time.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func ensureWindow() {
        let real = NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }

        if let existing = real.first {
            existing.makeKeyAndOrderFront(nil)
        } else {
            Self.openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
