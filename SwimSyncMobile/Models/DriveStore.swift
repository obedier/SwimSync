import Foundation
import SwiftUI

/// Holds the folder the player mounts as.
///
/// iOS has no equivalent of `NSWorkspace.didMountNotification` — a third-party
/// app cannot see volumes appear at all. The user picks the drive once in the
/// Files app and the grant is kept alive with a bookmark, which is as close to
/// "the Mac notices it automatically" as the platform allows.
@MainActor
final class DriveStore: ObservableObject {
    @Published private(set) var device: Device?
    @Published private(set) var contents: [DeviceTrack] = []
    @Published var problem: String?

    /// False when the chosen folder turns out to live on the iPhone itself.
    ///
    /// This matters more than it looks. `UIFileSharingEnabled` publishes this
    /// app's own Documents folder into Files as "SwimSync", so the folder
    /// picker offers it right alongside the real drive. Picking it produces a
    /// transfer that appears to succeed instantly, reports the phone's storage
    /// as the player's, and leaves the files on the phone.
    @Published private(set) var isExternal = false

    private let bookmarkKey = "playerFolderBookmark"
    private var scope: URL?

    var index: DeviceIndex { contents.indexed }
    var isConnected: Bool { device != nil }

    /// Where the files will actually land, as the user would recognise it.
    var destinationDescription: String {
        guard let volume = device?.volume else { return "—" }
        let parts = volume.pathComponents.suffix(2).filter { $0 != "/" }
        return parts.joined(separator: "/")
    }

    /// True when the picked folder is this app's own Documents directory.
    var isOwnDocuments: Bool {
        guard let volume = device?.volume else { return false }
        return volume.standardizedFileURL.path
            .hasPrefix(URL.documentsDirectory.standardizedFileURL.path)
    }

    init() { restore() }

    deinit {
        // Captured locally: `self` is main-actor isolated and deinit is not.
        scope?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Choosing

    func choose(_ url: URL) {
        adopt(url, rewriteBookmark: true)
    }

    /// Reconnect to whatever was picked last time. The drive is usually absent
    /// at launch, so failure here is normal and must not surface as an error.
    func restore() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale
        ) else { return }
        adopt(url, rewriteBookmark: stale, quiet: true)
    }

    /// Re-attach without asking, when possible.
    ///
    /// iOS gives a sandboxed app no way to *discover* the drive — there is no
    /// mount notification and no usable volume list — so the first connection
    /// always costs one trip through the Files picker. After that the
    /// security-scoped bookmark is enough, and this runs whenever the app comes
    /// to the foreground so plugging the player in and switching back is all
    /// that's needed.
    func reconnectIfNeeded() {
        if device != nil {
            refresh()
            // The volume can disappear underneath a live scope when the cable
            // is pulled; drop it rather than showing a phantom player.
            if let volume = device?.volume, !FileManager.default.fileExists(atPath: volume.path) {
                releaseScope()
                device = nil
                contents = []
            }
            return
        }
        restore()
    }

    /// Writes what iOS is willing to say about mounted volumes into the app
    /// container, where it can be pulled off the device with `devicectl`.
    /// Purely diagnostic — it answers "could this ever be automatic?" with
    /// evidence instead of assumption.
    func dumpVolumeDiagnostics() {
        let volume = device?.volume
        let external = isExternal
        let known = contents
        Task.detached(priority: .background) {
            Self.writeDiagnostics(volume: volume, isExternal: external, contents: known)
        }
    }

    /// `mountedVolumeURLs` can itself block while a slow external volume is
    /// attached, so this never runs on the main actor.
    private nonisolated static func writeDiagnostics(
        volume: URL?, isExternal: Bool, contents: [DeviceTrack]
    ) {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsInternalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIdentifierKey, .volumeURLKey
        ]
        var lines = ["mountedVolumeURLs probe"]

        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []
        ) ?? []
        lines.append("count: \(mounted.count)")
        for url in mounted {
            let v = try? url.resourceValues(forKeys: Set(keys))
            lines.append("""
              path=\(url.path)
              name=\(v?.volumeName ?? "nil") removable=\(String(describing: v?.volumeIsRemovable)) \
            internal=\(String(describing: v?.volumeIsInternal)) \
            total=\(v?.volumeTotalCapacity ?? -1)
            """)
        }

        if let volume {
            let v = try? volume.resourceValues(forKeys: Set(keys))
            lines.append("chosen: \(volume.path)")
            lines.append("  name=\(v?.volumeName ?? "nil") total=\(v?.volumeTotalCapacity ?? -1) free=\(v?.volumeAvailableCapacity ?? -1)")
            lines.append("  isExternal=\(isExternal) contents=\(contents.count)")
            for c in contents.prefix(40) { lines.append("    \(c.sizeBytes)\t\(c.name)") }
        }

        let out = URL.documentsDirectory.appendingPathComponent("volume-diagnostics.txt")
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    func forget() {
        releaseScope()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        device = nil
        contents = []
        problem = nil
        isExternal = false
    }

    private func adopt(_ url: URL, rewriteBookmark: Bool, quiet: Bool = false) {
        releaseScope()

        guard url.startAccessingSecurityScopedResource() else {
            if !quiet { problem = "iOS wouldn't grant access to that folder. Try picking it again." }
            return
        }
        scope = url

        // A bookmark can resolve to a drive that has since been unplugged; the
        // URL looks fine and every read comes back empty.
        guard FileManager.default.fileExists(atPath: url.path) else {
            releaseScope()
            if !quiet { problem = "That drive isn't connected." }
            return
        }

        if rewriteBookmark, let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }

        isExternal = Self.isOnAnotherVolume(url)
        device = Device.describing(url)
        problem = nil
        refresh()
    }

    /// iOS exposes no volume list, but it will say which volume a URL sits on.
    /// Anything sharing a volume with our own container is on-device storage;
    /// a real USB drive reports a different one.
    private static func isOnAnotherVolume(_ url: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let picked = try? url.resourceValues(forKeys: key).volumeIdentifier,
              let local = try? URL.documentsDirectory.resourceValues(forKeys: key).volumeIdentifier
        else {
            // Can't tell — fall back to the path test rather than claiming it
            // is external and letting a silent local copy happen again.
            return !url.standardizedFileURL.path
                .hasPrefix(URL.documentsDirectory.standardizedFileURL.path)
        }
        return !picked.isEqual(local)
    }

    private func releaseScope() {
        scope?.stopAccessingSecurityScopedResource()
        scope = nil
    }

    // MARK: - Contents

    /// Re-read the drive off the main thread.
    ///
    /// Listing a FAT32 stick behind a file provider means a `stat` per file
    /// over a ~1 MB/s link. Cheap on a Mac, but on the main actor it is enough
    /// to visibly stall the UI right after a transfer — the exact moment the
    /// app is expected to feel finished.
    func refresh() {
        guard let volume = device?.volume else { contents = []; return }
        let currentName = device?.name
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                Self.scan(volume, name: currentName)
            }.value
            guard let self else { return }
            self.contents = scan.tracks
            self.device = scan.device
        }
    }

    private nonisolated static func scan(
        _ volume: URL, name: String?
    ) -> (tracks: [DeviceTrack], device: Device) {
        let items: [URL] = (try? FileManager.default.contentsOfDirectory(
            at: volume,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let tracks: [DeviceTrack] = items
            .filter { Track.audioFormats.contains($0.pathExtension.lowercased()) }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return DeviceTrack(url: url, sizeBytes: Int64(size))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Capacity moves as files are added and removed.
        return (tracks, Device.describing(volume, name: name))
    }

    func delete(_ track: DeviceTrack) {
        do {
            try FileManager.default.removeItem(at: track.url)
        } catch {
            problem = "Couldn't delete \(track.name): \(error.localizedDescription)"
        }
        refresh()
    }

    /// Remove the given files from the player, off the main thread, and
    /// re-read the drive when done. Returns how many could not be removed.
    ///
    /// Used for two things: replacing a track that is being sent again, and
    /// erasing the player wholesale. Deleting on FAT32 behind a file provider
    /// is a round-trip per file over a slow link, so a batch of fifty is long
    /// enough to freeze the UI if it ran here.
    @discardableResult
    func remove(_ tracks: [DeviceTrack]) async -> Int {
        guard !tracks.isEmpty else { return 0 }
        let urls = tracks.map(\.url)
        let failures = await Task.detached(priority: .userInitiated) {
            Self.removeAll(urls)
        }.value
        if !failures.isEmpty {
            problem = "Couldn't delete \(failures.count) file\(failures.count == 1 ? "" : "s") from the player."
        }
        refresh()
        return failures.count
    }

    /// Erase every audio file the app can see on the player.
    ///
    /// Only what `contents` lists: top-level audio files. Anything else on the
    /// stick — firmware folders, system files the player relies on — is left
    /// alone, because "wipe the music" and "brick the player" should not be
    /// one tap apart.
    func eraseAll() async {
        guard isExternal else {
            problem = "That folder is on this iPhone, not the player. Pick the drive first."
            return
        }
        await remove(contents)
    }

    /// The device files matching a track, for replace-in-place.
    func tracks(named names: [String]) -> [DeviceTrack] {
        let wanted = Set(names.map { $0.lowercased() })
        return contents.filter { wanted.contains($0.name.lowercased()) }
    }

    private nonisolated static func removeAll(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            do {
                try FileManager.default.removeItem(at: url)
                return false
            } catch {
                return true
            }
        }
    }
}
