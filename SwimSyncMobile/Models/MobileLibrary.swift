import Foundation
import SwiftUI

/// The send queue.
///
/// There is no equivalent of the Mac's library scan here: iOS keeps Apple
/// Podcasts' downloads inside that app's own container, and no API exposes
/// them. Everything therefore arrives by explicit user action — the Files
/// picker or another app's share sheet — so this is a queue the user builds
/// rather than a folder the app reads.
@MainActor
final class MobileLibrary: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published var problem: String?

    /// Picker URLs stay valid only while their scope is claimed, and the copy
    /// happens long after the picker closes, so the scopes are held open for
    /// the lifetime of the queue entry.
    private var scopes: [String: URL] = [:]

    var totalBytes: Int64 { queue.reduce(0) { $0 + $1.sizeBytes } }

    func add(_ urls: [URL]) {
        var added = false

        for url in urls {
            guard !queue.contains(where: { $0.id == url.path }) else { continue }

            if url.startAccessingSecurityScopedResource() {
                scopes[url.path] = url
            }
            guard let track = Self.makeTrack(url) else {
                problem = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            queue.append(track)
            added = true
        }

        if added { Task { await enrich() } }
    }

    func remove(_ track: Track) {
        queue.removeAll { $0.id == track.id }
        release(track.id)
    }

    func removeAll(where shouldRemove: (Track) -> Bool) {
        for track in queue where shouldRemove(track) { release(track.id) }
        queue.removeAll(where: shouldRemove)
    }

    func clear() {
        queue.forEach { release($0.id) }
        queue.removeAll()
    }

    private func release(_ id: String) {
        scopes.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    /// Read tags concurrently, bounded so a big multi-select doesn't spawn
    /// hundreds of AVAsset readers at once.
    private func enrich() async {
        let pending = queue.filter { !$0.metadataLoaded }
        guard !pending.isEmpty else { return }

        var enriched: [String: Track] = [:]
        await withTaskGroup(of: Track.self) { group in
            var iterator = pending.makeIterator()
            var running = 0
            let limit = 4

            while running < limit, let t = iterator.next() {
                group.addTask { await t.loadingMetadata() }
                running += 1
            }
            for await result in group {
                enriched[result.id] = result
                if let t = iterator.next() { group.addTask { await t.loadingMetadata() } }
            }
        }

        queue = queue.map { enriched[$0.id] ?? $0 }
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
