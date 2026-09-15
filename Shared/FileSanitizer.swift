import Foundation

/// The half of `FileNaming` that has no dependencies: filename sanitising.
///
/// Declared here, on its own, so the share extension can compile it without
/// dragging in `Track` and AVFoundation. The rest of the enum lives in
/// `FileNaming.swift` as an extension.
enum FileNaming {
    /// FAT32 long names reject these outright; a few others confuse cheap
    /// firmware parsers, so they go too.
    private static let illegal = CharacterSet(charactersIn: #"\/:*?"<>|"# + "\u{0}")

    /// Strip characters FAT32 can't store and collapse the result.
    static func sanitize(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.replacingOccurrences(
            of: " {2,}", with: " ", options: .regularExpression
        )
        return collapsed.isEmpty ? "Track" : collapsed
    }

}
