import Foundation

/// One show as returned by the directory search. Value type — the UI holds
/// these in a list and diffs them, so identity has to come from the catalogue
/// id rather than object identity. Codable so favourites and history survive
/// a relaunch.
struct PodcastShow: Identifiable, Hashable, Sendable, Codable {
    /// iTunes `collectionId`. Stable for the life of the show, so it survives a
    /// re-search and keeps SwiftUI list animations sane.
    let id: Int
    let title: String
    let author: String

    /// The RSS feed. A show without one is useless to us — we can't list or
    /// download a single episode — so results lacking it never become a
    /// `PodcastShow` at all.
    let feedURL: URL

    let artworkURL: URL?
    let episodeCount: Int?
    let genre: String?
}

/// An episode found by searching the catalogue directly, paired with the show
/// it belongs to so the UI can download it or drill into the full feed.
struct EpisodeHit: Identifiable, Hashable, Sendable {
    var id: String { episode.id }
    let episode: FeedEpisode
    let show: PodcastShow
}

/// Search Apple's public podcast catalogue.
///
/// This is the iTunes Search API: no key, no account, no signing. It is rate
/// limited by IP at roughly 20 calls/minute, which is far above anything a
/// person typing in a search box will produce, but it does mean a tight
/// retry loop will start getting 403s.
///
/// The host is `itunes.apple.com` — several third-party write-ups cite a bare
/// `apple.com/search`, which does not resolve to this service.
enum PodcastDirectory {
    private static let searchEndpoint = "https://itunes.apple.com/search"
    private static let lookupEndpoint = "https://itunes.apple.com/lookup"

    /// The API caps at 200; 25 is a screenful and keeps the response under
    /// ~100 KB, which matters on a phone hitting this over cellular.
    private static let showLimit = 25

    /// Episode hits are smaller rows and people search for a specific one,
    /// so a longer list is worth the bytes.
    private static let episodeLimit = 50

    enum SearchError: LocalizedError {
        case badURL
        case transport(String)
        case httpStatus(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Could not build a search request for that text."
            case .transport(let detail):
                return "Could not reach the podcast directory: \(detail)"
            case .httpStatus(let code):
                return "The podcast directory returned an error (HTTP \(code))."
            case .malformedResponse:
                return "The podcast directory sent a response we couldn't read."
            }
        }
    }

    /// - Returns: up to `showLimit` shows, in the directory's own relevance
    ///   order. Empty for a blank term — the API treats an empty `term` as a
    ///   400, and asking is pointless anyway.
    static func search(_ term: String) async throws -> [PodcastShow] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let payload: SearchPayload = try await fetch(searchEndpoint, query: [
            "media": "podcast", "entity": "podcast",
            "limit": String(showLimit), "term": trimmed
        ])
        return payload.results.compactMap(Self.show(from:))
    }

    /// Search individual episodes across every show in the catalogue.
    ///
    /// The same endpoint with `entity=podcastEpisode`; each row carries enough
    /// of its parent show (id, name, feed, artwork) to build a `PodcastShow`
    /// without a second request.
    static func searchEpisodes(_ term: String) async throws -> [EpisodeHit] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let payload: SearchPayload = try await fetch(searchEndpoint, query: [
            "media": "podcast", "entity": "podcastEpisode",
            "limit": String(episodeLimit), "term": trimmed
        ])
        return payload.results.compactMap(Self.hit(from:))
    }

    /// Resolve catalogue ids to shows in one request. Used by the charts,
    /// which list ids and names but not feeds. Results come back in the
    /// order given, minus anything without a usable feed.
    static func lookup(ids: [Int]) async throws -> [PodcastShow] {
        guard !ids.isEmpty else { return [] }
        let payload: SearchPayload = try await fetch(lookupEndpoint, query: [
            "entity": "podcast",
            "id": ids.map(String.init).joined(separator: ",")
        ])
        let byID = Dictionary(
            payload.results.compactMap(Self.show(from:)).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { byID[$0] }
    }

    // MARK: - Transport

    /// One GET with query items, decoded. `URLComponents` does the
    /// percent-encoding, including the `+` and `&` that a naive
    /// `addingPercentEncoding` leaves intact inside a query value.
    private static func fetch<T: Decodable>(_ endpoint: String, query: [String: String]) async throws -> T {
        guard var components = URLComponents(string: endpoint) else { throw SearchError.badURL }
        components.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw SearchError.badURL }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw SearchError.transport(error.localizedDescription)
        }

        // A non-HTTP response can't happen for an https URL, but treating it as
        // a hard failure is cheaper than pretending the status was fine.
        guard let http = response as? HTTPURLResponse else { throw SearchError.malformedResponse }
        guard http.statusCode == 200 else { throw SearchError.httpStatus(http.statusCode) }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SearchError.malformedResponse
        }
    }

    // MARK: - Mapping

    /// Maps one raw result, dropping anything we can't act on. Feeds that are
    /// missing, empty, or not a parseable URL are silently skipped rather than
    /// failing the whole search — one bad row in a catalogue of millions
    /// shouldn't blank the results list.
    private static func show(from raw: SearchResult) -> PodcastShow? {
        guard let id = raw.collectionId, let feedURL = feedURL(raw.feedUrl) else { return nil }

        let title = raw.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = raw.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return PodcastShow(
            id: id,
            title: title.isEmpty ? (author.isEmpty ? "Untitled show" : author) : title,
            author: author,
            feedURL: feedURL,
            artworkURL: artwork(raw),
            episodeCount: raw.trackCount,
            genre: raw.primaryGenreName ?? raw.genres?.first?.name
        )
    }

    /// An episode row is a show row with the episode's own fields on top, so
    /// the parent show is built from the same mapping.
    private static func hit(from raw: SearchResult) -> EpisodeHit? {
        guard let show = show(from: raw),
              let audio = raw.episodeUrl.flatMap(URL.init(string:)), audio.scheme != nil
        else { return nil }

        let title = raw.trackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let millis = raw.trackTimeMillis ?? 0
        let episode = FeedEpisode(
            title: title.isEmpty ? show.title : title,
            showTitle: show.title,
            published: raw.releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) },
            duration: millis > 0 ? TimeInterval(millis) / 1000 : nil,
            byteCount: 0,
            audioURL: audio,
            summary: raw.description ?? raw.shortDescription
        )
        return EpisodeHit(episode: episode, show: show)
    }

    private static func feedURL(_ raw: String?) -> URL? {
        guard let feedString = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !feedString.isEmpty,
              let feedURL = URL(string: feedString),
              feedURL.scheme != nil, feedURL.host != nil
        else { return nil }
        return feedURL
    }

    /// artworkUrl600 is absent on a small number of older entries; the 100px
    /// version is always present and still legible at list-row size.
    private static func artwork(_ raw: SearchResult) -> URL? {
        [raw.artworkUrl600, raw.artworkUrl160, raw.artworkUrl100]
            .compactMap { $0 }
            .compactMap(URL.init(string:))
            .first
    }

    // MARK: - Wire format

    /// Every field is optional because the search endpoint is shared across
    /// media types and omits keys that don't apply to a given entity.
    private struct SearchPayload: Decodable {
        let results: [SearchResult]
    }

    private struct SearchResult: Decodable {
        let collectionId: Int?
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let artworkUrl160: String?
        let artworkUrl100: String?
        let trackCount: Int?
        let primaryGenreName: String?
        let genres: [Genre]?

        // Episode-only fields.
        let trackName: String?
        let episodeUrl: String?
        let releaseDate: String?
        let trackTimeMillis: Int?
        let description: String?
        let shortDescription: String?
    }

    /// Show rows list genres as bare strings; episode rows list them as
    /// objects with a `name`. One type reads both so neither shape can fail
    /// the whole decode.
    private struct Genre: Decodable {
        let name: String?

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
                name = text
                return
            }
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            name = try keyed.decodeIfPresent(String.self, forKey: .name)
        }

        private enum CodingKeys: String, CodingKey { case name }
    }
}
