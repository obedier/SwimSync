import Foundation

/// One downloadable episode taken from an RSS feed.
///
/// Identified by its audio URL rather than the feed's `<guid>`: guids are
/// frequently duplicated, occasionally absent, and sometimes rewritten by
/// hosting migrations, whereas two entries pointing at the same audio file are
/// the same episode for our purposes.
struct FeedEpisode: Identifiable, Hashable, Sendable, Codable {
    var id: String { audioURL.absoluteString }

    let title: String
    let showTitle: String
    let published: Date?

    /// From `<itunes:duration>`. Advisory only — many feeds round it, and some
    /// omit it entirely, so never treat it as the real asset length.
    let duration: TimeInterval?

    /// From the enclosure's `length` attribute. Zero when absent, which is
    /// common enough that the UI has to cope with an unknown size rather than
    /// assuming a missing value means an empty file.
    let byteCount: Int64

    let audioURL: URL
    let summary: String?
}

/// RSS 2.0 podcast feed parsing on Foundation's `XMLParser` — a streaming SAX
/// parser, so a 5 MB feed with 800 episodes never materialises as a tree. It is
/// also strict: an undeclared HTML entity such as `&nbsp;` aborts the whole
/// document, which real feeds do ship, hence the repair pass below.
enum FeedParser {
    enum FeedError: LocalizedError {
        case transport(String)
        case httpStatus(Int)
        case unreadable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .transport(let detail): "Could not download the feed: \(detail)"
            case .httpStatus(let code): "The feed server returned an error (HTTP \(code))."
            case .unreadable(let detail): "Could not read the feed: \(detail)"
            case .empty: "That feed has no downloadable episodes."
            }
        }
    }

    /// Containers AVFoundation can actually open. Used as a fallback when an
    /// enclosure declares a useless MIME type — `octet-stream` and
    /// `application/x-mpeg` are both seen in the wild.
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "aac", "wav", "aif", "aiff", "flac", "ogg", "oga", "opus", "wma"
    ]

    /// One page of a feed. Most feeds are a single page; the ones that follow
    /// RFC 5005 paginate their archive and link each page to the next.
    struct Page: Sendable {
        let episodes: [FeedEpisode]
        let next: URL?
    }

    /// Feeds that paginate can run to hundreds of pages for a daily show that
    /// has been going for a decade. This is generous enough to reach the
    /// start of almost anything while bounding a runaway `next` loop.
    static let maxPages = 40

    /// Parse a feed body. Never throws for individual malformed items — they
    /// are dropped — only for a document that cannot be parsed at all.
    static func episodes(from data: Data, fallbackShowTitle: String) throws -> [FeedEpisode] {
        try page(from: data, fallbackShowTitle: fallbackShowTitle).episodes
    }

    /// As `episodes(from:)`, also reporting where the next page lives.
    static func page(from data: Data, fallbackShowTitle: String) throws -> Page {
        if let parsed = run(data, fallbackShowTitle: fallbackShowTitle) { return parsed }

        // Second pass: neutralise the undeclared named entities that abort
        // strict XML. Only reached when the first pass failed, so the extra
        // copy of the body costs nothing in the common case.
        let repaired = repairingEntities(data)
        guard let parsed = run(repaired, fallbackShowTitle: fallbackShowTitle) else {
            throw FeedError.unreadable("the XML is malformed")
        }
        return parsed
    }

    private static func run(_ data: Data, fallbackShowTitle: String) -> Page? {
        let delegate = FeedDelegate(fallbackShowTitle: fallbackShowTitle)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Namespaces off so `itunes:duration` arrives as one qualified name;
        // turning them on strips the prefix and lets `duration` collide with
        // the other namespaces that use the same word.
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return Page(episodes: delegate.episodes, next: delegate.nextPage)
    }

    /// Fetch and parse, preferring TLS. A large share of feeds still publish
    /// `http://` URLs even though the host has supported TLS for years, and App
    /// Transport Security blocks plain http, so the upgrade is usually the only
    /// attempt that can succeed — the original is kept for hosts with no TLS.
    ///
    /// Follows `rel="next"` links so a paginated archive comes back whole. A
    /// later page that fails is dropped rather than failing the fetch — the
    /// first page is the one the user is waiting on, and a partial archive
    /// beats an error.
    static func fetch(_ feedURL: URL, showTitle: String) async throws -> [FeedEpisode] {
        let data = try await download(candidates(for: feedURL))
        let first = try page(from: data, fallbackShowTitle: showTitle)
        guard !first.episodes.isEmpty else { throw FeedError.empty }

        // Deduplicated from the first page on: feeds do repeat an item, and
        // SwiftUI's list identity falls apart on a duplicated id.
        var seen: Set<String> = []
        var all = first.episodes.filter { seen.insert($0.id).inserted }
        var visited: Set<String> = [feedURL.absoluteString]
        var next = first.next

        while let url = next, all.count < 10_000, visited.count < maxPages,
              visited.insert(url.absoluteString).inserted {
            try Task.checkCancellation()
            let pageData: Data
            do {
                pageData = try await download(candidates(for: url))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                break
            }
            guard let more = try? page(from: pageData, fallbackShowTitle: showTitle) else { break }
            // A page with nothing new means the feed is looping on itself.
            let fresh = more.episodes.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { break }
            all += fresh
            next = more.next
        }
        return all
    }

    /// URLs to try in order: an https upgrade first when the original is plain
    /// http, otherwise just the original. Shared with `EpisodeDownloader`.
    static func candidates(for url: URL) -> [URL] {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [url] }
        components.scheme = "https"
        guard let upgraded = components.url else { return [url] }
        return [upgraded, url]
    }

    /// Tries each candidate, keeping the first transport error to report if
    /// they all fail. A non-200 counts as a failure worth retrying, since a
    /// misconfigured http-to-https redirect chain often 404s on one scheme.
    private static func download(_ urls: [URL]) async throws -> Data {
        var firstError: Error?
        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw FeedError.httpStatus(http.statusCode)
                }
                return data
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let feedError = firstError as? FeedError { throw feedError }
        throw FeedError.transport(firstError?.localizedDescription ?? "no usable address")
    }

    /// Replaces the handful of HTML named entities that appear in feeds but are
    /// undefined in XML. Everything else is left for the parser to decode.
    private static func repairingEntities(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        let replacements = [
            "&nbsp;": "&#160;", "&mdash;": "&#8212;", "&ndash;": "&#8211;", "&hellip;": "&#8230;",
            "&rsquo;": "&#8217;", "&lsquo;": "&#8216;", "&rdquo;": "&#8221;", "&ldquo;": "&#8220;",
            "&eacute;": "&#233;", "&trade;": "&#8482;", "&copy;": "&#169;", "&reg;": "&#174;"
        ]
        for (entity, numeric) in replacements {
            text = text.replacingOccurrences(of: entity, with: numeric)
        }
        return Data(text.utf8)
    }
}

// MARK: - SAX delegate

/// `XMLParser` requires a reference-type delegate — the one class here, kept
/// private so callers only ever see values.
private final class FeedDelegate: NSObject, XMLParserDelegate {
    private struct Partial {
        var title = "", summary = "", pubDate = "", duration = ""
        var audioURL: URL?
        var byteCount: Int64 = 0
    }

    private let fallbackShowTitle: String
    private var channelTitle = "", text = ""

    /// `<atom:link rel="next">` at channel level, when the feed paginates.
    private(set) var nextPage: URL?
    private var stack: [String] = []
    private var current: Partial?
    private var collected: [Partial] = []

    /// RFC 822 as podcasts actually use it. `en_US_POSIX` is mandatory: with a
    /// user locale, a device set to a non-Gregorian calendar or a 24-hour
    /// override silently fails to match the English day and month names.
    private let dateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",   // Wed, 05 Aug 2026 10:30:00 GMT
        "EEE, dd MMM yyyy HH:mm:ss Z",     // …10:30:00 +0000
        "EEE, dd MMM yyyy HH:mm zzz",      // seconds omitted
        "dd MMM yyyy HH:mm:ss zzz",        // weekday omitted
        "yyyy-MM-dd'T'HH:mm:ssZ"           // a minority of feeds emit ISO 8601
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    init(fallbackShowTitle: String) {
        self.fallbackShowTitle = fallbackShowTitle
    }

    /// Built at the end, so a `<channel><title>` placed after the items wins.
    var episodes: [FeedEpisode] {
        let show = channelTitle.isEmpty ? fallbackShowTitle : channelTitle
        return collected.compactMap { item in
            guard let audioURL = item.audioURL else { return nil }
            let title = Self.clean(item.title), summary = Self.clean(item.summary)
            return FeedEpisode(
                title: title.isEmpty ? show : title,
                showTitle: show,
                published: date(from: item.pubDate),
                duration: Self.seconds(from: item.duration),
                byteCount: item.byteCount,
                audioURL: audioURL,
                summary: summary.isEmpty ? nil : summary
            )
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        stack.append(name)
        text = ""

        if name == "item" { current = Partial() }

        // Pagination lives on the channel, never inside an item. The prefix is
        // whatever the feed chose for the Atom namespace, so only the local
        // name is checked.
        if current == nil, nextPage == nil,
           name.split(separator: ":").last == "link",
           attributes["rel"]?.lowercased() == "next",
           let href = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: href), url.scheme != nil {
            nextPage = url
        }

        guard name == "enclosure", current != nil else { return }

        // First usable enclosure wins; a few feeds attach a chapters file or a
        // transcript as a second enclosure on the same item.
        if current?.audioURL == nil, let url = Self.audioURL(from: attributes) {
            current?.audioURL = url
            current?.byteCount = Int64(attributes["length"] ?? "") ?? 0
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    /// Show notes are nearly always CDATA, which bypasses `foundCharacters`.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        defer {
            if !stack.isEmpty { stack.removeLast() }
            text = ""
        }

        if name == "item", let finished = current {
            collected.append(finished)
            current = nil
            return
        }

        if current != nil {
            switch name {
            case "title": current?.title = text
            case "pubDate": current?.pubDate = text
            case "itunes:duration": current?.duration = text
            case "description", "itunes:summary":
                if current?.summary.isEmpty ?? false { current?.summary = text }
            default: break
            }
            return
        }

        // Outside an item: only the channel's own title counts. Guarding on the
        // parent keeps `<channel><image><title>` from overwriting it, which it
        // otherwise would on every feed that carries channel artwork.
        if name == "title", channelTitle.isEmpty, stack.dropLast().last == "channel" {
            channelTitle = Self.clean(text)
        }
    }

    // MARK: Field parsing

    private static func audioURL(from attributes: [String: String]) -> URL? {
        guard let raw = attributes["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw), url.scheme != nil
        else { return nil }

        let type = attributes["type"]?.lowercased() ?? ""
        let matchesType = type.hasPrefix("audio/")
        let matchesExtension = FeedParser.audioExtensions.contains(url.pathExtension.lowercased())
        return (matchesType || matchesExtension) ? url : nil
    }

    /// `<itunes:duration>` is specified as `HH:MM:SS` but is just as often a
    /// bare second count, and sometimes `MM:SS`. All three are accepted; a
    /// value we can't read becomes nil rather than a wrong number.
    private static func seconds(from raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count <= 3 else { return nil }

        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total > 0 ? total : nil
    }

    private func date(from raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
