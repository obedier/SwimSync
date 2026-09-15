import Foundation

/// The player displays raw filenames, so what we name a file on the device is
/// the entire user-facing experience there. Podcast downloads arrive as UUIDs
/// (`0FA2D107-C94C-….mp3`), which would be useless on a 1-line display.
extension FileNaming {
    private static let uuidPattern = try? NSRegularExpression(
        pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
        options: .caseInsensitive
    )

    /// True when a filename carries no human meaning and should be replaced by
    /// ID3 metadata if we have any.
    static func isOpaque(_ stem: String) -> Bool {
        guard let uuidPattern else { return false }
        let range = NSRange(stem.startIndex..., in: stem)
        return uuidPattern.firstMatch(in: stem, range: range) != nil
    }

    /// Final on-device filename for a track.
    /// - Parameter index: when non-nil, prefixed as `01 - ` so the player's
    ///   filename ordering matches the order you queued things.
    static func deviceName(for track: Track, index: Int?, useMetadata: Bool) -> String {
        let stem = track.url.deletingPathExtension().lastPathComponent
        var base = stem

        if useMetadata || isOpaque(stem) {
            if let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                if let show = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !show.isEmpty, !title.localizedCaseInsensitiveContains(show) {
                    base = "\(show) - \(title)"
                } else {
                    base = title
                }
            }
        }

        base = sanitize(base)

        // Keep well inside FAT32's 255-char limit; some firmware truncates far
        // earlier and then shows a mangled name.
        let cap = 90
        if base.count > cap {
            base = String(base.prefix(cap)).trimmingCharacters(in: .whitespaces)
        }

        if let index {
            return String(format: "%02d - %@.mp3", index, base)
        }
        return base + ".mp3"
    }

    /// Avoid clobbering an existing file on the device.
    static func uniqued(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name.lowercased()) else { return name }
        let stem = (name as NSString).deletingPathExtension
        for n in 2...99 {
            let candidate = "\(stem) (\(n)).mp3"
            if !existing.contains(candidate.lowercased()) { return candidate }
        }
        return name
    }
}
