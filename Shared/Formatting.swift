import Foundation

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        if b <= 0 { return "0 MB" }
        let mb = Double(b) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(b) / 1024) }
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    static func duration(_ s: TimeInterval?) -> String {
        guard let s, s.isFinite, s > 0 else { return "—" }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// Human transfer estimate at the device's real measured write speed.
    static func eta(bytes: Int64, rate: Double = Theme.measuredWriteBytesPerSec) -> String {
        guard bytes > 0, rate > 0 else { return "—" }
        return clock(Double(bytes) / rate)
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let t = Int(seconds.rounded())
        if t < 60 { return "\(t)s" }
        let m = t / 60, s = t % 60
        if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
        let h = m / 60
        return "\(h)h \(m % 60)m"
    }

    static func rate(_ bytesPerSec: Double) -> String {
        guard bytesPerSec.isFinite, bytesPerSec > 0 else { return "—" }
        return String(format: "%.2f MB/s", bytesPerSec / 1_048_576)
    }
}
