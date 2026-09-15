import Foundation

/// The player as a writable volume: a mounted disk on macOS, a folder vended by
/// the Files app on iOS. Both platforms describe it the same way.
struct Device: Equatable {
    let volume: URL
    let name: String
    let totalBytes: Int64
    let freeBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var fractionUsed: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    /// Read capacity straight off a volume URL. Returns zeroes when the
    /// filesystem declines to report — some Files providers do.
    static func describing(_ volume: URL, name: String? = nil) -> Device {
        let v = try? volume.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ])
        return Device(
            volume: volume,
            name: name ?? v?.volumeName ?? volume.lastPathComponent,
            totalBytes: Int64(v?.volumeTotalCapacity ?? 0),
            freeBytes: Int64(v?.volumeAvailableCapacity ?? 0)
        )
    }
}

/// A file that is already sitting on the player. Deliberately thinner than
/// `Track` — nothing reads tags off the device, because doing so would mean
/// pulling every file back across a 1 MB/s link just to draw a list.
struct DeviceTrack: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let sizeBytes: Int64
    var name: String { url.lastPathComponent }
}

extension Collection where Element == DeviceTrack {
    /// Shape the contents into what `DeviceIndex` consumes.
    var indexed: DeviceIndex {
        DeviceIndex(files: map { ($0.name, $0.sizeBytes) })
    }
}
