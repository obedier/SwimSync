import SwiftUI

/// One directory result. Secondary line carries author, then genre and episode
/// count — enough to tell two shows with the same name apart. An optional rank
/// turns it into a chart row.
struct ShowRow: View {
    let show: PodcastShow
    var rank: Int?

    @EnvironmentObject var podcasts: PodcastLibrary

    var body: some View {
        HStack(spacing: 11) {
            if let rank {
                Text("\(rank)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 22, alignment: .trailing)
            }

            ShowArtwork(url: show.artworkURL, size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(show.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !show.author.isEmpty {
                    Text(show.author)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }

                if let detail = secondary {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if podcasts.isFavorite(show) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.favorite)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textFaint.opacity(0.7))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private var secondary: String? {
        var parts: [String] = []
        if let genre = show.genre, !genre.isEmpty { parts.append(genre) }
        if let count = show.episodeCount, count > 0 { parts.append("\(count) episodes") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Square artwork plus title, for horizontal strips of shows.
struct ShowTile: View {
    let show: PodcastShow
    var size: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ShowArtwork(url: show.artworkURL, size: size, radius: Theme.radiusM)
            Text(show.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: size, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
    }
}

/// Heart toggle used on shows and episodes alike.
struct HeartButton: View {
    let isOn: Bool
    var size: CGFloat = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "heart.fill" : "heart")
                .font(.system(size: size))
                .foregroundStyle(isOn ? Theme.favorite : Theme.textFaint)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Remove from favorites" : "Add to favorites")
    }
}

/// Artwork with a fixed footprint in every phase, so a row never changes height
/// when the image finally arrives and shoves the list under the user's thumb.
struct ShowArtwork: View {
    let url: URL?
    var size: CGFloat
    var radius: CGFloat = Theme.radiusS

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                placeholder("waveform.slash")
            case .empty:
                placeholder("waveform")
            @unknown default:
                placeholder("waveform")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }

    private func placeholder(_ icon: String) -> some View {
        ZStack {
            Theme.surfaceRaised
            Image(systemName: icon)
                .font(.system(size: size * 0.3, weight: .ultraLight))
                .foregroundStyle(Theme.textFaint)
        }
    }
}

/// Empty / loading / error placard. One shape for all of them keeps the screen
/// from feeling like it jumped to a different app when a search goes wrong.
struct StatusPanel<Action: View>: View {
    let icon: String
    let title: String
    var detail: String?
    var tint: Color = Theme.textFaint
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(tint)

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)

            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
        .panel()
    }
}

extension StatusPanel where Action == EmptyView {
    init(icon: String, title: String, detail: String? = nil, tint: Color = Theme.textFaint) {
        self.init(icon: icon, title: title, detail: detail, tint: tint) { EmptyView() }
    }
}
