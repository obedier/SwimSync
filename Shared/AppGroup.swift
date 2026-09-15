import Foundation

/// The container the share extension and the app both see.
///
/// A share extension runs in its own sandbox and cannot reach the app's
/// Documents, so everything shared is dropped into an app-group folder and
/// the app sweeps it the next time it comes to the foreground.
enum AppGroup {
    static let identifier = "group.com.osamabedier.swimsync"

    /// `Inbox/` inside the group container, created on first use. Nil when
    /// the app group entitlement is missing, which only happens on a build
    /// signed without it.
    static var inbox: URL? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return nil
        }
        let folder = root.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Sidecar extension for a shared web address the app should fetch and
    /// read aloud. Kept deliberately odd so nothing else claims it.
    static let webLinkExtension = "weblink"

    /// A name that will not collide with what is already in the folder.
    static func uniqueURL(in folder: URL, stem: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}
