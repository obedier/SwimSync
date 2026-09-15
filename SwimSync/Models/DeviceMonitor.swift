import Foundation
import AppKit
import Combine

/// Watches for the player mounting and unmounting.
///
/// The device presents as a generic USB mass-storage volume with no
/// distinguishing vendor string, so identification is by shape: removable,
/// ejectable, and holding a FAT filesystem. The remembered volume name wins
/// when several candidates are present.
@MainActor
final class DeviceMonitor: ObservableObject {
    @Published private(set) var device: Device?
    @Published private(set) var contents: [DeviceTrack] = []

    /// Fires when a volume we consider "the player" appears.
    let didAttach = PassthroughSubject<Device, Never>()

    /// Which volume name to prefer when more than one removable FAT disk is
    /// attached. Defaults to the player's label; persists across launches.
    var preferredName: String {
        get { UserDefaults.standard.string(forKey: "preferredVolumeName") ?? "SWIM" }
        set { UserDefaults.standard.set(newValue, forKey: "preferredVolumeName") }
    }

    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let mounted = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in self.rescan(justMounted: mounted) }
        })

        observers.append(nc.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.rescan(justMounted: nil) }
        })

        rescan(justMounted: nil)
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
    }

    func rescan(justMounted: URL?) {
        let previous = device?.volume
        let found = Self.candidates(preferring: preferredName)
        device = found.first

        if let device {
            VolumeHygiene.suppressIndexing(on: device.volume)
            loadContents()
            // Only announce a genuinely new attachment, not a refresh.
            if previous != device.volume || justMounted == device.volume {
                didAttach.send(device)
            }
        } else {
            contents = []
        }
    }

    func refresh() { rescan(justMounted: nil) }

    func loadContents() {
        guard let device else { contents = []; return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: device.volume,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { contents = []; return }

        contents = items
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return DeviceTrack(url: url, sizeBytes: Int64(size))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func delete(_ track: DeviceTrack) {
        try? FileManager.default.removeItem(at: track.url)
        if let device { VolumeHygiene.dotClean(device.volume) }
        refresh()
    }

    func eject() {
        guard let device else { return }
        let volume = device.volume
        // Last chance to leave the card tidy — sidecars written lazily during
        // the session get swept here before the volume goes away.
        VolumeHygiene.purgeSidecars(volume)
        try? VolumeHygiene.eject(volume)
        refresh()
    }

    /// Removable, ejectable volumes that look like a media player rather than a
    /// backup disk. Sorted so the remembered name sorts first.
    static func candidates(preferring name: String) -> [Device] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeLocalizedFormatDescriptionKey
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []

        var out: [Device] = []
        for url in mounted {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let removable = (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)
            let internalDisk = v.volumeIsInternal ?? false
            guard removable, !internalDisk else { continue }

            let format = (v.volumeLocalizedFormatDescription ?? "").lowercased()
            let isFAT = format.contains("fat") || format.contains("ms-dos") || format.contains("exfat")
            guard isFAT else { continue }

            out.append(Device(
                volume: url,
                name: v.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(v.volumeTotalCapacity ?? 0),
                freeBytes: Int64(v.volumeAvailableCapacity ?? 0)
            ))
        }

        return out.sorted { a, b in
            if a.name == name { return true }
            if b.name == name { return false }
            return a.name < b.name
        }
    }
}
