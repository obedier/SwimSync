import Foundation
import SwiftUI

/// An episode the user has starred, with the show it came from so it can be
/// downloaded or opened later without a fresh search.
struct SavedEpisode: Identifiable, Hashable, Codable {
    var id: String { episode.id }
    let episode: FeedEpisode
    let show: PodcastShow
    let savedAt: Date
}

/// One completed download. Kept even after the file is gone from the phone —
/// this is the memory of what was listened to, not a file index.
struct DownloadRecord: Identifiable, Hashable, Codable {
    var id: String { episode.id }
    let episode: FeedEpisode
    let show: PodcastShow
    let downloadedAt: Date
}

/// Favourite shows and episodes, plus the history of every download.
///
/// Persisted as one JSON file in Documents. The whole thing is a few hundred
/// rows at most, so it is rewritten in full on every change rather than
/// reaching for a database. Every mutation produces a new array — the
/// published properties are replaced, never edited in place.
@MainActor
final class PodcastLibrary: ObservableObject {
    @Published private(set) var favoriteShows: [PodcastShow] = []
    @Published private(set) var favoriteEpisodes: [SavedEpisode] = []
    /// Newest first.
    @Published private(set) var downloads: [DownloadRecord] = []

    private let fileURL: URL

    init(fileURL: URL = URL.documentsDirectory.appendingPathComponent("podcast-library.json")) {
        self.fileURL = fileURL
        load()
    }

    /// Every show the user has downloaded from, most recent first.
    var recentShows: [PodcastShow] {
        var seen: Set<Int> = []
        return downloads.map(\.show).filter { seen.insert($0.id).inserted }
    }

    var isEmpty: Bool {
        favoriteShows.isEmpty && favoriteEpisodes.isEmpty && downloads.isEmpty
    }

    // MARK: - Shows

    func isFavorite(_ show: PodcastShow) -> Bool {
        favoriteShows.contains { $0.id == show.id }
    }

    func toggleFavorite(_ show: PodcastShow) {
        if isFavorite(show) {
            favoriteShows = favoriteShows.filter { $0.id != show.id }
        } else {
            favoriteShows = [show] + favoriteShows
        }
        save()
    }

    // MARK: - Episodes

    func isFavorite(_ episode: FeedEpisode) -> Bool {
        favoriteEpisodes.contains { $0.id == episode.id }
    }

    func toggleFavorite(_ episode: FeedEpisode, from show: PodcastShow) {
        if isFavorite(episode) {
            favoriteEpisodes = favoriteEpisodes.filter { $0.id != episode.id }
        } else {
            let saved = SavedEpisode(episode: episode, show: show, savedAt: Date())
            favoriteEpisodes = [saved] + favoriteEpisodes
        }
        save()
    }

    // MARK: - History

    func hasDownloaded(_ episode: FeedEpisode) -> Bool {
        downloads.contains { $0.id == episode.id }
    }

    /// Episodes downloaded from this show, newest first.
    func downloads(from show: PodcastShow) -> [DownloadRecord] {
        downloads.filter { $0.show.id == show.id }
    }

    /// A second download of the same episode moves it to the front rather
    /// than adding a duplicate row.
    func recordDownload(_ episode: FeedEpisode, from show: PodcastShow) {
        let record = DownloadRecord(episode: episode, show: show, downloadedAt: Date())
        downloads = [record] + downloads.filter { $0.id != episode.id }
        save()
    }

    func forgetDownloads(from show: PodcastShow) {
        downloads = downloads.filter { $0.show.id != show.id }
        save()
    }

    func clearHistory() {
        downloads = []
        save()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var favoriteShows: [PodcastShow] = []
        var favoriteEpisodes: [SavedEpisode] = []
        var downloads: [DownloadRecord] = []
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // A file this app cannot read is one it wrote with an older schema;
        // starting empty is better than refusing to launch.
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favoriteShows = snapshot.favoriteShows
        favoriteEpisodes = snapshot.favoriteEpisodes
        downloads = snapshot.downloads
    }

    private func save() {
        let snapshot = Snapshot(
            favoriteShows: favoriteShows,
            favoriteEpisodes: favoriteEpisodes,
            downloads: downloads
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Losing a favourite is annoying, not dangerous, and there is no
            // sensible UI for "the disk write failed" on a phone.
            NSLog("PodcastLibrary: could not save — \(error.localizedDescription)")
        }
    }
}
