import Foundation
import AppKit
import SwiftUI

/// Which shelf a source feeds. Podcasts and Music get their own tabs because
/// they are browsed completely differently — podcasts by recency, music by
/// artist — and mixing a few hundred songs into a podcast queue makes the
/// recency ordering useless.
enum SourceKind: String, CaseIterable, Identifiable {
    case podcasts, music, files
    var id: String { rawValue }

    var title: String {
        switch self {
        case .podcasts: return "Podcasts"
        case .music: return "Music"
        case .files: return "Files"
        }
    }

    var icon: String {
        switch self {
        case .podcasts: return "antenna.radiowaves.left.and.right"
        case .music: return "music.note"
        case .files: return "folder"
        }
    }

    var tint: Color {
        switch self {
        case .podcasts: return Theme.library
        case .music: return Theme.music
        case .files: return Theme.textDim
        }
    }
}

/// A folder the app scans for audio. Access is held via a security-scoped
/// bookmark so the grant survives relaunches — the Apple Podcasts cache lives
/// in a Group Container that macOS will not hand over on a bare path alone.
struct Source: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    var kind: SourceKind = .files
    var isDefault: Bool = false

    var displayName: String {
        if url.path.contains("com.apple.podcasts") { return "Apple Podcasts" }
        if url.path.contains("/Music/Music/Media") { return "Music Library" }
        return url.lastPathComponent
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var byKind: [SourceKind: [Track]] = [:]
    @Published private(set) var sources: [Source] = []
    @Published private(set) var isScanning = false
    @Published var accessDenied: Source?

    /// Ad-hoc files dropped onto the window. Not a folder, so they're tracked
    /// separately and never persisted.
    @Published private(set) var dropped: [Track] = []

    /// Where Apple Podcasts keeps completed downloads.
    static let podcastsCache = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Group Containers")
        .appendingPathComponent("243LU875E5.groups.com.apple.podcasts")
        .appendingPathComponent("Library/Cache")

    /// Music.app's media folder. The directory is `Media.localized` on a system
    /// that has ever shown a localized Finder name and plain `Media` otherwise,
    /// so both spellings are probed rather than assumed.
    static var musicMediaFolder: URL? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/Music")
        for name in ["Media.localized", "Media"] {
            let candidate = root.appendingPathComponent(name).appendingPathComponent("Music")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private var bookmarkStore = BookmarkStore()
    private var scopedURLs: [URL] = []

    init() {
        sources = bookmarkStore.restoreAll()

        // Seed the two built-in shelves the first time, and re-add either one
        // if a previous session removed only the other.
        if !sources.contains(where: { $0.kind == .podcasts }) {
            sources.append(Source(url: Self.podcastsCache, kind: .podcasts, isDefault: true))
        }
        if !sources.contains(where: { $0.kind == .music }), let music = Self.musicMediaFolder {
            sources.append(Source(url: music, kind: .music, isDefault: true))
        }

        Task { await scan() }
    }

    deinit {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    func sources(for kind: SourceKind) -> [Source] {
        sources.filter { $0.kind == kind }
    }

    /// Everything on one shelf. Dropped files ride along on Files so a fresh
    /// drop is immediately visible.
    func tracks(for kind: SourceKind) -> [Track] {
        let scanned = byKind[kind] ?? []
        return kind == .files ? dropped + scanned : scanned
    }

    /// Union of every shelf — used for whole-library operations.
    var allTracks: [Track] { SourceKind.allCases.flatMap(tracks(for:)) }

    func addSource(_ url: URL, kind: SourceKind = .files) {
        guard !sources.contains(where: { $0.url == url }) else { return }
        bookmarkStore.save(url, kind: kind)
        sources.append(Source(url: url, kind: kind))
        Task { await scan() }
    }

    func removeSource(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        bookmarkStore.remove(source.url)
        Task { await scan() }
    }

    func addDropped(_ urls: [URL]) {
        let fm = FileManager.default
        var found: [URL] = []

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                found.append(contentsOf: Self.audioFiles(in: url))
            } else if Track.audioFormats.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }

        let existing = Set(dropped.map(\.id)).union(allTracks.map(\.id))
        let fresh = found
            .filter { !existing.contains($0.path) }
            .compactMap(Self.makeTrack)

        guard !fresh.isEmpty else { return }
        dropped.append(contentsOf: fresh)
        Task { await enrich() }
    }

    func clearDropped() { dropped.removeAll() }

    func scan() async {
        isScanning = true
        defer { isScanning = false }

        var collected: [SourceKind: [Track]] = [:]
        var denied: Source?

        for source in sources {
            let scoped = bookmarkStore.beginAccess(source.url)
            if scoped { scopedURLs.append(source.url) }

            let urls = Self.audioFiles(in: source.url)
            if urls.isEmpty && !FileManager.default.isReadableFile(atPath: source.url.path) {
                denied = source
            }
            collected[source.kind, default: []].append(contentsOf: urls.compactMap(Self.makeTrack))
        }

        // Podcast workflows are recency-driven; music is browsed by artist.
        byKind = collected.mapValues { tracks in
            tracks.sorted { $0.modified > $1.modified }
        }
        if var music = byKind[.music] {
            music.sort { a, b in
                let (ga, gb) = (a.groupingArtist, b.groupingArtist)
                if ga != gb { return ga.localizedStandardCompare(gb) == .orderedAscending }
                if a.displayAlbum != b.displayAlbum {
                    return a.displayAlbum.localizedStandardCompare(b.displayAlbum) == .orderedAscending
                }
                return a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
            }
            byKind[.music] = music
        }
        accessDenied = denied

        await enrich()
    }

    /// Read tags concurrently. Bounded so a large library doesn't spawn hundreds
    /// of AVAsset readers at once.
    private func enrich() async {
        let pending = (dropped + byKind.values.flatMap { $0 }).filter { !$0.metadataLoaded }
        guard !pending.isEmpty else { return }

        var enriched: [String: Track] = [:]
        await withTaskGroup(of: Track.self) { group in
            var iterator = pending.makeIterator()
            let limit = 6
            var running = 0

            while running < limit, let t = iterator.next() {
                group.addTask { await t.loadingMetadata() }
                running += 1
            }
            for await result in group {
                enriched[result.id] = result
                if let t = iterator.next() {
                    group.addTask { await t.loadingMetadata() }
                }
            }
        }

        byKind = byKind.mapValues { $0.map { enriched[$0.id] ?? $0 } }
        dropped = dropped.map { enriched[$0.id] ?? $0 }
    }

    private static func audioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in e where Track.audioFormats.contains(url.pathExtension.lowercased()) {
            out.append(url)
        }
        return out
    }

    private static func makeTrack(_ url: URL) -> Track? {
        guard let v = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ), let size = v.fileSize, size > 0 else { return nil }
        return Track(
            url: url,
            sizeBytes: Int64(size),
            modified: v.contentModificationDate ?? .distantPast
        )
    }
}

/// Persists folder access grants across launches.
private struct BookmarkStore {
    private let dataKey = "sourceBookmarks"
    private let kindKey = "sourceKinds"

    private var raw: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: dataKey) as? [String: Data] ?? [:] }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: dataKey) }
    }

    private var kinds: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: kindKey) as? [String: String] ?? [:] }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: kindKey) }
    }

    func save(_ url: URL, kind: SourceKind) {
        var current = raw
        // A bookmark is only obtainable for a path we can currently reach; the
        // path is still recorded either way so the shelf survives a relaunch.
        if let data = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            current[url.path] = data
            raw = current
        }
        var k = kinds
        k[url.path] = kind.rawValue
        kinds = k
    }

    func remove(_ url: URL) {
        var current = raw
        current.removeValue(forKey: url.path)
        raw = current
        var k = kinds
        k.removeValue(forKey: url.path)
        kinds = k
    }

    func restoreAll() -> [Source] {
        Set(raw.keys).union(kinds.keys).sorted().map { path in
            Source(
                url: URL(fileURLWithPath: path),
                kind: kinds[path].flatMap(SourceKind.init(rawValue:)) ?? .files
            )
        }
    }

    /// Resolving the bookmark is what actually re-establishes the grant; the
    /// resolved URL is retained by the caller so the scope stays open.
    @discardableResult
    func beginAccess(_ url: URL) -> Bool {
        guard let data = raw[url.path] else { return false }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return false }
        return resolved.startAccessingSecurityScopedResource()
    }
}
