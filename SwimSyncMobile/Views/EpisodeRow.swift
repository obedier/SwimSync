import SwiftUI

/// One episode, plus the controls that keep it and get it onto the phone.
///
/// The download control is the whole point of the row, so it carries all three
/// download states itself rather than deferring to a sheet or a swipe action:
/// not here yet, coming down now (tap to stop), already here (tap to queue it
/// again).
///
/// `standalone` is for rows shown outside their show — search hits and saved
/// episodes — where the artwork and show name are what make the row readable,
/// and where tapping the title opens the show.
struct EpisodeRow: View {
    let episode: FeedEpisode
    let show: PodcastShow
    var standalone = false

    @EnvironmentObject var downloader: EpisodeDownloader
    @EnvironmentObject var podcasts: PodcastLibrary

    /// Built once for the whole list. DateFormatter construction is expensive
    /// enough that a per-row instance is visible as stutter when scrolling a
    /// feed with a few hundred episodes. MainActor-isolated because rows only
    /// ever read it during layout, which keeps it safe without a lock.
    @MainActor
    private static let publishedFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// The USB players this app exists to feed decode MP3 and WAV and nothing
    /// else. Flagging the format here — before the download, not after the
    /// transfer silently produces an unplayable file — is the earliest point we
    /// know it. An extensionless URL tells us nothing, so it isn't flagged.
    private static let playableExtensions: Set<String> = ["mp3", "wav"]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if standalone {
                NavigationLink(value: show) {
                    ShowArtwork(url: show.artworkURL, size: 44)
                }
                .buttonStyle(.plain)
            }

            if standalone {
                NavigationLink(value: show) { text }
                    .buttonStyle(.plain)
            } else {
                text
            }

            Spacer(minLength: 4)

            HeartButton(isOn: podcasts.isFavorite(episode)) {
                podcasts.toggleFavorite(episode, from: show)
            }
            .frame(width: 26, height: 30)

            control
                .frame(width: 30, height: 30)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(isDownloaded ? Color.white.opacity(0.03) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(episode.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isDownloaded ? Theme.textDim : Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if standalone {
                Text(show.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.library)
                    .lineLimit(1)
            }

            HStack(spacing: 7) {
                Text(metadata)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)

                if let format = unsupportedFormat {
                    TrackBadge(text: format, tint: Theme.warn)
                }
                if isDownloaded {
                    TrackBadge(text: "on phone", tint: Theme.ok)
                } else if podcasts.hasDownloaded(episode) {
                    TrackBadge(text: "downloaded before", tint: Theme.library)
                }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Download control

    @ViewBuilder
    private var control: some View {
        if isDownloaded {
            // Re-queues the file that is already here — the way to send an
            // episode to the player a second time without downloading again.
            Button {
                downloader.download(episode, from: show)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.ok)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Downloaded — tap to queue again")
        } else if downloader.isDownloading(episode) {
            Button {
                downloader.cancel(episode)
            } label: {
                DownloadRing(progress: downloader.progress[episode.id] ?? 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel download")
        } else {
            Button {
                downloader.download(episode, from: show)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.library)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download episode")
        }
    }

    // MARK: - Derived text

    private var isDownloaded: Bool { downloader.localURL(for: episode) != nil }

    /// Date · duration · size, with unknown parts dropped rather than rendered
    /// as a row of em dashes.
    private var metadata: String {
        var parts: [String] = []
        if let published = episode.published {
            parts.append(Self.publishedFormat.string(from: published))
        }
        if let duration = episode.duration, duration > 0 {
            parts.append(Fmt.duration(duration))
        }
        if episode.byteCount > 0 {
            parts.append(Fmt.bytes(episode.byteCount))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var unsupportedFormat: String? {
        let ext = episode.audioURL.pathExtension.lowercased()
        guard !ext.isEmpty, !Self.playableExtensions.contains(ext) else { return nil }
        return ext.uppercased()
    }
}

/// Determinate ring with a stop glyph inside it. A bare ring reads as "busy";
/// the glyph is what tells the user the whole thing is a cancel button.
struct DownloadRing: View {
    let progress: Double

    /// A hairline of arc at 0% so the control never looks like an empty circle
    /// in the moment between the tap and the first byte.
    private var trimmed: Double { min(max(progress, 0.03), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.library.opacity(0.22), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: trimmed)
                .stroke(Theme.library, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "stop.fill")
                .font(.system(size: 7))
                .foregroundStyle(Theme.library)
        }
        .frame(width: 21, height: 21)
        .animation(.linear(duration: 0.25), value: trimmed)
    }
}
