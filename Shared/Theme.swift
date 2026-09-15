import SwiftUI

/// Design tokens. Dark, editorial, high-contrast — closer to a pro audio tool
/// than a stock SwiftUI form. Everything visual traces back to here.
enum Theme {
    // Surfaces, back to front.
    static let bg = Color(red: 0.055, green: 0.058, blue: 0.070)
    static let surface = Color(red: 0.086, green: 0.092, blue: 0.110)
    static let surfaceRaised = Color(red: 0.118, green: 0.126, blue: 0.149)
    static let hairline = Color.white.opacity(0.07)

    // Text.
    static let text = Color(red: 0.937, green: 0.945, blue: 0.960)
    static let textDim = Color(red: 0.569, green: 0.596, blue: 0.647)
    static let textFaint = Color(red: 0.376, green: 0.400, blue: 0.447)

    // Semantic accents — amber is "the device", cyan is "the library",
    // violet is "music", green is "already there".
    static let accent = Color(red: 0.98, green: 0.70, blue: 0.20)
    static let accentDim = Color(red: 0.98, green: 0.70, blue: 0.20).opacity(0.16)
    static let library = Color(red: 0.35, green: 0.78, blue: 0.90)
    static let music = Color(red: 0.68, green: 0.56, blue: 0.96)
    static let ok = Color(red: 0.36, green: 0.84, blue: 0.55)
    static let warn = Color(red: 0.98, green: 0.45, blue: 0.36)
    /// Rose is "kept": favourite shows and episodes.
    static let favorite = Color(red: 0.96, green: 0.44, blue: 0.60)

    // Rhythm — deliberately not uniform.
    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 10
    static let radiusL: CGFloat = 16

    /// Measured ceiling on this hardware: the player enumerates at USB full
    /// speed (12 Mbit/s), and writes settle around 0.95 MB/s once Spotlight is
    /// kept off the volume. Used for transfer-time estimates.
    static let measuredWriteBytesPerSec: Double = 950_000
}

extension View {
    /// Raised panel treatment: subtle fill, hairline border, soft drop.
    func panel(_ radius: CGFloat = Theme.radiusL) -> some View {
        self
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

/// Uppercase micro-label used above each pane. Establishes hierarchy without
/// spending vertical space on a big heading.
struct SectionLabel: View {
    let text: String
    var tint: Color = Theme.textFaint

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(tint)
    }
}
