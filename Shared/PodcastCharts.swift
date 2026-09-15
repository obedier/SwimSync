import Foundation

/// Apple's public "Top Shows" chart.
///
/// The marketing-tools feed lists ids, names and artwork but not RSS feeds, so
/// it is only half of what a `PodcastShow` needs. The ids are resolved with a
/// single directory lookup, which keeps a chart of 50 to two requests total.
enum PodcastCharts {
    private static let host = "https://rss.marketingtools.apple.com/api/v2"

    /// Apple caps this feed at 100.
    static let defaultLimit = 50

    enum ChartError: LocalizedError {
        case badURL
        case transport(String)
        case httpStatus(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .badURL: "Could not build the chart request."
            case .transport(let detail): "Could not load the top podcasts: \(detail)"
            case .httpStatus(let code): "The chart server returned an error (HTTP \(code))."
            case .malformedResponse: "The chart server sent a response we couldn't read."
            }
        }
    }

    /// The user's storefront — `us`, `gb`, `de`… — falling back to `us`,
    /// which is also what Apple serves for regions with no chart of their own.
    static var localCountry: String {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        return region.count == 2 ? region : "us"
    }

    /// Chart order is preserved. Shows the directory can't resolve to a feed
    /// are dropped rather than shown as dead rows, so the list can come back
    /// a little shorter than `limit`.
    static func top(limit: Int = defaultLimit, country: String = localCountry) async throws -> [PodcastShow] {
        let ids: [Int]
        do {
            ids = try await chartIDs(limit: limit, country: country)
        } catch ChartError.httpStatus(404) where country != "us" {
            // A storefront without a podcast chart 404s; the US chart is the
            // one every other region falls back to anyway.
            ids = try await chartIDs(limit: limit, country: "us")
        }
        return try await PodcastDirectory.lookup(ids: ids)
    }

    private static func chartIDs(limit: Int, country: String) async throws -> [Int] {
        let clamped = max(1, min(limit, 100))
        guard let url = URL(string: "\(host)/\(country)/podcasts/top/\(clamped)/podcasts.json") else {
            throw ChartError.badURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw ChartError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw ChartError.malformedResponse }
        guard http.statusCode == 200 else { throw ChartError.httpStatus(http.statusCode) }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ChartError.malformedResponse
        }

        // Ids arrive as strings in this feed even though the directory treats
        // them as integers everywhere else.
        return payload.feed.results.compactMap { Int($0.id) }
    }

    private struct Payload: Decodable {
        let feed: Feed
    }

    private struct Feed: Decodable {
        let results: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
    }
}
