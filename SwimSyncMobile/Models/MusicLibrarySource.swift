import Foundation
import MediaPlayer
import AVFoundation

/// One song in the phone's Music library, reduced to what the app needs.
struct LibrarySong: Identifiable, Hashable {
    let id: UInt64
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let assetURL: URL?
    let isCloud: Bool
    let isProtected: Bool

    /// Apple Music subscription tracks are FairPlay-encrypted and report no
    /// asset URL; cloud tracks that were never downloaded report none either.
    var isExportable: Bool { assetURL != nil && !isProtected }

    var unavailableReason: String? {
        if isProtected { return "Apple Music" }
        if assetURL == nil { return isCloud ? "not downloaded" : "unavailable" }
        return nil
    }
}

/// The Music library as a source of tracks.
///
/// iOS never exposes the files behind the library; the MediaPlayer framework
/// offers each song as an `ipod-library://` asset instead. Choosing one reads
/// the audio out through `AudioTranscoder` into Documents/Music as an MP3,
/// after which it is an ordinary local file the queue can send.
@MainActor
final class MusicLibrarySource: ObservableObject {
    @Published private(set) var authorization = MPMediaLibrary.authorizationStatus()
    @Published private(set) var songs: [LibrarySong] = []
    @Published private(set) var isLoading = false
    /// Song id → 0...1 while an export is running.
    @Published private(set) var progress: [UInt64: Double] = [:]
    @Published var problem: String?

    /// Called on the main actor as each MP3 lands.
    var onExported: ((LibrarySong, URL) -> Void)?

    private var tasks: [UInt64: Task<Void, Never>] = [:]

    var isAuthorized: Bool { authorization == .authorized }

    /// `Documents/Music`. Documents rather than Caches for the same reason
    /// episodes live there: the system may evict Caches under pressure.
    var folder: URL {
        let folder = URL.documentsDirectory.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func requestAccess() async {
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        if isAuthorized { reload() }
    }

    /// Reads the whole song list off the main actor; a few thousand items is
    /// enough to stutter the tab switch otherwise.
    func reload() {
        guard isAuthorized, !isLoading else { return }
        isLoading = true
        Task { [weak self] in
            let songs = await Task.detached(priority: .userInitiated) { Self.querySongs() }.value
            guard let self else { return }
            self.songs = songs
            self.isLoading = false
        }
    }

    private nonisolated static func querySongs() -> [LibrarySong] {
        let items = MPMediaQuery.songs().items ?? []
        return items.map { item in
            LibrarySong(
                id: item.persistentID,
                title: item.title ?? "Untitled",
                artist: item.artist ?? item.albumArtist ?? "Unknown Artist",
                album: item.albumTitle ?? "",
                duration: item.playbackDuration,
                assetURL: item.assetURL,
                isCloud: item.isCloudItem,
                isProtected: item.hasProtectedAsset
            )
        }
        .sorted { a, b in
            let artist = a.artist.localizedCaseInsensitiveCompare(b.artist)
            if artist != .orderedSame { return artist == .orderedAscending }
            let album = a.album.localizedCaseInsensitiveCompare(b.album)
            if album != .orderedSame { return album == .orderedAscending }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    // MARK: - Export

    func isExporting(_ song: LibrarySong) -> Bool { tasks[song.id] != nil }

    /// The MP3 already made from this song, or nil.
    func localURL(for song: LibrarySong) -> URL? {
        let candidate = destination(for: song)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Filename is the on-device experience, so artist and title, not an id.
    func destination(for song: LibrarySong) -> URL {
        let raw = song.artist.isEmpty ? song.title : "\(song.artist) - \(song.title)"
        var stem = FileNaming.sanitize(raw)
        if stem.count > 120 { stem = String(stem.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return folder.appendingPathComponent("\(stem).mp3")
    }

    func export(_ song: LibrarySong) {
        guard tasks[song.id] == nil else { return }

        // Already converted — from an earlier session or a re-tap. Report it
        // straight away so the caller's queueing path is the same.
        if let existing = localURL(for: song) {
            onExported?(song, existing)
            return
        }
        guard let source = song.assetURL, song.isExportable else {
            problem = song.isProtected
                ? "“\(song.title)” is an Apple Music track. It's copy-protected, so it can't be put on the player."
                : "“\(song.title)” isn't downloaded to this iPhone. Download it in the Music app first."
            return
        }

        progress[song.id] = 0
        let destination = destination(for: song)
        let tags = ID3Writer.Tags(title: song.title, artist: song.artist, album: song.album)

        // The transcoder is a nonisolated async function, so its blocking read
        // loop runs on the cooperative pool, not the main actor — and because
        // it runs *in* this task rather than a detached one, `cancel()` below
        // reaches it. A detached task would have ignored the cancellation.
        tasks[song.id] = Task { [weak self] in
            let outcome: Result<Void, Error>
            do {
                try await AudioTranscoder.exportMP3(
                    from: AVURLAsset(url: source), to: destination, tags: tags
                ) { fraction in
                    Task { @MainActor [weak self] in self?.report(fraction, for: song.id) }
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            self?.finish(song, at: destination, outcome: outcome)
        }
    }

    func cancel(_ song: LibrarySong) {
        tasks.removeValue(forKey: song.id)?.cancel()
        progress[song.id] = nil
    }

    private func report(_ fraction: Double, for id: UInt64) {
        guard tasks[id] != nil else { return }
        progress[id] = fraction
    }

    private func finish(_ song: LibrarySong, at url: URL, outcome: Result<Void, Error>) {
        guard tasks.removeValue(forKey: song.id) != nil else { return }
        progress[song.id] = nil
        switch outcome {
        case .success:
            onExported?(song, url)
        case .failure(let error):
            if case AudioTranscoder.TranscodeError.cancelled = error { return }
            // Apple Music tracks sometimes slip through the flags looking
            // exportable; the reader failing is the honest signal.
            problem = "Couldn't convert “\(song.title)” — \(error.localizedDescription)."
        }
    }
}
