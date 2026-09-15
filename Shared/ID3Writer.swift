import Foundation

/// Writes a minimal ID3v2.3 tag: title, artist, album.
///
/// The player shows filenames, not tags, so this is for the app's own
/// benefit — `Track.loadingMetadata` reads these back to name the file on
/// the way to the device — and for anything else the MP3 is later opened in.
enum ID3Writer {
    struct Tags {
        var title: String?
        var artist: String?
        var album: String?

        var isEmpty: Bool { [title, artist, album].allSatisfy { ($0 ?? "").isEmpty } }
    }

    static func tag(_ tags: Tags) -> Data {
        guard !tags.isEmpty else { return Data() }

        var frames = Data()
        for (id, value) in [("TIT2", tags.title), ("TPE1", tags.artist), ("TALB", tags.album)] {
            guard let value, !value.isEmpty else { continue }
            frames.append(textFrame(id, value))
        }

        var header = Data("ID3".utf8)
        header.append(contentsOf: [0x03, 0x00, 0x00])   // v2.3, no flags
        header.append(syncsafe(UInt32(frames.count)))
        return header + frames
    }

    /// Text frame, UTF-16 with BOM (encoding byte 1) so any title survives.
    private static func textFrame(_ id: String, _ value: String) -> Data {
        var body = Data([0x01, 0xFF, 0xFE])
        for unit in value.utf16 {
            body.append(UInt8(unit & 0xFF))
            body.append(UInt8(unit >> 8))
        }
        var frame = Data(id.utf8)
        var size = UInt32(body.count).bigEndian
        frame.append(Data(bytes: &size, count: 4))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(body)
        return frame
    }

    /// Four 7-bit bytes — the ID3 header refuses a set high bit so a decoder
    /// scanning for frame sync never mistakes the size for audio.
    private static func syncsafe(_ n: UInt32) -> Data {
        Data([
            UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F),
            UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)
        ])
    }
}
