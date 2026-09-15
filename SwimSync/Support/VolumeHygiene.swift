import Foundation
import AppKit

/// Everything that keeps macOS from sabotaging transfers to a cheap FAT32
/// device. These are not micro-optimisations: on this hardware, leaving
/// Spotlight to index the volume cut measured write throughput from
/// ~944 KB/s to ~303 KB/s — a 3.1x penalty on a link that only has
/// ~1.1 MB/s to give in the first place.
enum VolumeHygiene {

    /// Keep the indexer and FSEvents off the device.
    ///
    /// `mdutil -i off` needs root, but a `.metadata_never_index` sentinel at the
    /// volume root achieves the same thing with no privileges.
    static func suppressIndexing(on volume: URL) {
        let fm = FileManager.default

        let sentinel = volume.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: sentinel.path) {
            fm.createFile(atPath: sentinel.path, contents: Data())
        }

        let fsevents = volume.appendingPathComponent(".fseventsd")
        try? fm.createDirectory(at: fsevents, withIntermediateDirectories: true)
        let noLog = fsevents.appendingPathComponent("no_log")
        if !fm.fileExists(atPath: noLog.path) {
            fm.createFile(atPath: noLog.path, contents: Data())
        }
    }

    /// FAT32 has no native extended-attribute support, so macOS spills xattrs
    /// (notably `com.apple.provenance`, applied automatically on write) into
    /// AppleDouble sidecars named `._Track.mp3`. Cheap players happily list
    /// those as separate, unplayable phantom tracks.
    ///
    /// Stripping xattrs from the file we just wrote stops the sidecar being
    /// regenerated; `dot_clean` clears any that already exist.
    static func stripXattrs(at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }

            let size = listxattr(path, nil, 0, 0)
            guard size > 0 else { return }

            var buf = [CChar](repeating: 0, count: size)
            guard listxattr(path, &buf, size, 0) > 0 else { return }

            // The buffer is a run of NUL-terminated attribute names.
            var name = [CChar]()
            for ch in buf {
                if ch == 0 {
                    if !name.isEmpty {
                        name.append(0)
                        _ = removexattr(path, name, 0)
                        name.removeAll()
                    }
                } else {
                    name.append(ch)
                }
            }
        }
    }

    /// Clear AppleDouble sidecars, reliably.
    ///
    /// Two passes with a settle gap, because the FSKit msdos driver writes the
    /// `._name` sidecar lazily — a single `dot_clean` immediately after the
    /// last write races the flush and leaves sidecars behind. `com.apple.
    /// provenance` itself cannot be removed (macOS refuses, so `stripXattrs`
    /// alone is not enough), which makes this the only thing that actually works.
    static func purgeSidecars(_ volume: URL) {
        sync()
        dotClean(volume)
        Thread.sleep(forTimeInterval: 0.4)
        sync()
        dotClean(volume)
    }

    /// Fold and delete any AppleDouble sidecars left on the volume.
    @discardableResult
    static func dotClean(_ volume: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/dot_clean")
        p.arguments = ["-m", volume.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return false
        }

        // dot_clean skips protected dirs; sweep the root ourselves as a backstop.
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: volume.path) {
            for item in items where item.hasPrefix("._") || item == ".DS_Store" {
                try? fm.removeItem(at: volume.appendingPathComponent(item))
            }
        }
        return true
    }

    /// Flush the buffer cache so progress reflects bytes actually on flash.
    static func sync() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sync")
        try? p.run()
        p.waitUntilExit()
    }

    static func eject(_ volume: URL) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
    }
}

/// Wires the macOS housekeeping into the shared transfer engine.
struct MacHygiene: TransferHygiene {
    func prepare(_ volume: URL) { VolumeHygiene.suppressIndexing(on: volume) }
    func afterFile(_ url: URL) { VolumeHygiene.stripXattrs(at: url) }
    func finish(_ volume: URL) { VolumeHygiene.purgeSidecars(volume) }
}
