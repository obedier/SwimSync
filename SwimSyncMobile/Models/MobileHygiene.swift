import Foundation
import UIKit

/// What iOS needs around a transfer: none of the Mac's volume housekeeping,
/// but two things the Mac never worries about.
///
/// The screen must not lock — a locked phone suspends the app within seconds
/// and the copy dies mid-file — and the system is asked for the grace period
/// it grants a backgrounded app, so a quick trip to another app to answer a
/// message does not kill a 100 MB copy at 90%.
final class MobileHygiene: TransferHygiene, @unchecked Sendable {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func prepare(_ volume: URL) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
            self.endBackgroundTask()
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SwimSync transfer") {
                // Time's up: iOS is about to suspend the app regardless.
                self.endBackgroundTask()
            }
        }
    }

    func afterFile(_ url: URL) {}

    func finish(_ volume: URL) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
