import Foundation

/// Answers "is this episode already on the player?".
///
/// Harder than it looks, because a file's name changes on the way across: ID3
/// titles replace UUID stems, FAT32-illegal characters are substituted, long
/// names are truncated, and a `01 - ` ordering prefix is prepended. Comparing
/// raw filenames would report every transferred track as missing.
///
/// So both sides are reduced to the same normal form, and byte size is used as
/// a second, independent signal — the copy is byte-exact, and an MP3's length
/// in bytes is effectively a fingerprint.
struct DeviceIndex {
    /// Normalised name → the filenames on the device that reduce to it.
    private let byName: [String: [String]]
    /// Byte size → the filenames on the device with exactly that size.
    private let bySize: [Int64: [String]]

    static let empty = DeviceIndex(files: [])

    init(files: [(name: String, sizeBytes: Int64)]) {
        byName = Dictionary(grouping: files.map(\.name), by: Self.normalize)
        bySize = Dictionary(
            grouping: files.filter { $0.sizeBytes > 0 },
            by: \.sizeBytes
        ).mapValues { $0.map(\.name) }
    }

    var isEmpty: Bool { byName.isEmpty && bySize.isEmpty }

    /// True when this track appears to have already been transferred.
    ///
    /// Both naming modes are tested, not just the one currently selected: a
    /// track copied with ID3 naming on is still "already there" after the
    /// toggle is switched off, and vice versa.
    func contains(_ track: Track) -> Bool {
        !matchingNames(for: track).isEmpty
    }

    /// The device filenames this track appears to already be — by size, or by
    /// either naming mode. Used to replace a file in place when the user asks
    /// for a track to be sent again.
    func matchingNames(for track: Track) -> [String] {
        var found = bySize[track.sizeBytes] ?? []
        for useMetadata in [true, false] {
            let candidate = FileNaming.deviceName(
                for: track, index: nil, useMetadata: useMetadata
            )
            found += byName[Self.normalize(candidate)] ?? []
        }
        // Stable order, no duplicates: a file can match by both size and name.
        var seen: Set<String> = []
        return found.filter { seen.insert($0).inserted }
    }

    /// Strip everything the transfer adds or alters, leaving the part that
    /// identifies the episode: no extension, no `01 - ` prefix, no ` (2)`
    /// collision suffix, whitespace collapsed, case-folded.
    static func normalize(_ filename: String) -> String {
        var s = (filename as NSString).deletingPathExtension
        s = s.replacingOccurrences(
            of: #"^\d{1,3}\s*-\s*"#, with: "", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\s*\(\d{1,2}\)$"#, with: "", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
