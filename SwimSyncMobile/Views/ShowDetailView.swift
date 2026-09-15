import SwiftUI

/// One show: its artwork and metadata, then every episode in its feed with a
/// download control each, and a filter box for finding one in a long archive.
///
/// The feed is fetched on appear rather than cached with the search result —
/// feeds are hundreds of kilobytes of XML and most search results are never
/// opened, so paying for them up front would make every search slower for the
/// benefit of one row.
struct ShowDetailView: View {
    let show: PodcastShow

    @EnvironmentObject var downloader: EpisodeDownloader
    @EnvironmentObject var podcasts: PodcastLibrary
    @State private var feedState: FeedState = .loading
    @State private var filter = ""

    enum FeedState {
        case loading
        case loaded([FeedEpisode])
        case empty
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                content
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HeartButton(isOn: podcasts.isFavorite(show)) {
                    podcasts.toggleFavorite(show)
                }
            }
        }
        .task { await load() }
        .alert("Download failed", isPresented: problemBinding) {
            Button("OK") { downloader.problem = nil }
        } message: {
            Text(downloader.problem ?? "")
        }
    }

    private var problemBinding: Binding<Bool> {
        Binding(
            get: { downloader.problem != nil },
            set: { if !$0 { downloader.problem = nil } }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            ShowArtwork(url: show.artworkURL, size: 96, radius: Theme.radiusM)

            VStack(alignment: .leading, spacing: 5) {
                Text(show.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !show.author.isEmpty {
                    Text(show.author)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let genre = show.genre, !genre.isEmpty {
                        TrackBadge(text: genre, tint: Theme.library)
                    }
                    let downloaded = podcasts.downloads(from: show).count
                    if downloaded > 0 {
                        TrackBadge(text: "\(downloaded) downloaded", tint: Theme.ok)
                    }
                }

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - Episodes

    @ViewBuilder
    private var content: some View {
        switch feedState {
        case .loading:
            StatusPanel(icon: "antenna.radiowaves.left.and.right", title: "Loading episodes…") {
                ProgressView().tint(Theme.library)
            }

        case .loaded(let episodes):
            episodeList(episodes)

        case .empty:
            StatusPanel(
                icon: "waveform.slash",
                title: "No episodes in this feed",
                detail: "The show is listed in the directory, but its feed didn't return anything we can download."
            )

        case .failed(let why):
            StatusPanel(icon: "exclamationmark.triangle", title: "Couldn't read the feed", detail: why, tint: Theme.warn) {
                Button("Retry") { Task { await load() } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.library)
            }
        }
    }

    private func episodeList(_ episodes: [FeedEpisode]) -> some View {
        let shown = filtered(episodes)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Episodes", tint: Theme.library)
                Spacer()
                Text(shown.count == episodes.count ? "\(episodes.count)" : "\(shown.count) of \(episodes.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }

            filterField

            if shown.isEmpty {
                Text("No episodes match “\(filter)”.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textDim)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { episode in
                        EpisodeRow(episode: episode, show: show)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Feeds with a decade of daily episodes run to thousands of rows; a
    /// filter box is what makes "see all the episodes" usable rather than
    /// just true.
    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textFaint)

            TextField("Filter episodes", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
    }

    private func filtered(_ episodes: [FeedEpisode]) -> [FeedEpisode] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return episodes }
        return episodes.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.summary?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        feedState = .loading
        do {
            let episodes = try await FeedParser.fetch(show.feedURL, showTitle: show.title)
            feedState = episodes.isEmpty ? .empty : .loaded(episodes)
        } catch {
            feedState = .failed(error.localizedDescription)
        }
    }
}
