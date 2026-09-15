import Foundation
import AVFoundation

/// One MP3 in the library. Immutable value type — metadata enrichment produces
/// a new copy rather than mutating in place.
struct Track: Identifiable, Hashable {
    let id: String          // absolute path, stable across scans
    let url: URL
    let sizeBytes: Int64
    let modified: Date

    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    var metadataLoaded: Bool = false

    var filename: String { url.lastPathComponent }
    var stem: String { url.deletingPathExtension().lastPathComponent }

    /// Lowercased container extension — `mp3`, `m4a`, `wav`…
    var format: String { url.pathExtension.lowercased() }

    /// These players are MP3 decoders with a bit of PCM support bolted on.
    /// Anything else is likely to copy across fine and then refuse to play, so
    /// the UI flags it rather than letting it fail silently on the device.
    var isLikelyPlayable: Bool { Track.playableFormats.contains(format) }

    /// Apple Music streaming downloads are FairPlay-encrypted and cannot be
    /// copied off the machine in a usable form at all.
    var isDRMProtected: Bool { format == "m4p" }

    static let playableFormats: Set<String> = ["mp3", "wav"]

    /// Every container worth showing in a picker, playable or not.
    static let audioFormats: Set<String> = [
        "mp3", "m4a", "m4b", "m4p", "aac", "wav", "aiff", "aif", "flac", "wma", "ogg"
    ]

    /// What we show in the list. Falls back to the filename when there are no
    /// usable tags — except for UUID filenames, which are shown as-is only
    /// because there is nothing better to say yet.
    var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return stem
    }

    /// For a podcast this is the show; for music, the artist. Falls back to the
    /// album so a track with only album tags still groups sensibly.
    var displayShow: String {
        for candidate in [artist, album] {
            if let s = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return ""
    }

    var displayAlbum: String {
        album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Heading used to bucket the music list. Music.app lays its media folder
    /// out as `Artist/Album/Track`, so the parent directories are a reliable
    /// fallback when a file carries no usable tags.
    var groupingArtist: String {
        if let a = artist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { return a }
        let artistDir = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return artistDir.isEmpty ? "Unknown Artist" : artistDir
    }

    /// Flags a track whose filename carries no meaning, so the UI can explain
    /// that it will be renamed from its tags on the way to the device.
    var hasOpaqueName: Bool { FileNaming.isOpaque(stem) }

    init(url: URL, sizeBytes: Int64, modified: Date) {
        self.id = url.path
        self.url = url
        self.sizeBytes = sizeBytes
        self.modified = modified
    }

    /// Read ID3/common metadata. AVFoundation handles the tag-version zoo that
    /// podcast feeds produce far more reliably than parsing frames by hand.
    func loadingMetadata() async -> Track {
        var copy = self
        copy.metadataLoaded = true

        let asset = AVURLAsset(url: url)

        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
            copy.duration = seconds
        }

        guard let items = try? await asset.load(.commonMetadata) else { return copy }

        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                copy.title = try? await item.load(.stringValue)
            case .commonKeyArtist, .commonKeyAuthor:
                if copy.artist == nil { copy.artist = try? await item.load(.stringValue) }
            case .commonKeyAlbumName:
                if copy.album == nil { copy.album = try? await item.load(.stringValue) }
            default:
                break
            }
        }
        return copy
    }

    static func == (a: Track, b: Track) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}
