import SwiftUI

/// What the top chart request is doing.
enum ChartState {
    case loading
    case loaded([PodcastShow])
    case failed(String)
}

/// The Find tab before anything is typed: what the user has kept, what they
/// have pulled down before, and what everyone else is listening to.
///
/// Order is deliberate — the user's own shows come first because they are the
/// ones most likely to be wanted, and the chart is last because it is the
/// same for everyone.
struct BrowseSections: View {
    let chart: ChartState
    let onRetryChart: () -> Void

    @EnvironmentObject var podcasts: PodcastLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !podcasts.favoriteShows.isEmpty {
                strip(title: "Favorite shows", shows: podcasts.favoriteShows, tint: Theme.favorite)
            }
            if !podcasts.favoriteEpisodes.isEmpty {
                savedEpisodes
            }
            if !podcasts.recentShows.isEmpty {
                strip(title: "Downloaded before", shows: podcasts.recentShows, tint: Theme.library)
            }
            topChart
        }
    }

    // MARK: - Strips

    private func strip(title: String, shows: [PodcastShow], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: title, tint: tint)
                Spacer()
                Text("\(shows.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(shows) { show in
                        NavigationLink(value: show) {
                            ShowTile(show: show)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Let the artwork run to the panel edge instead of stopping
                // at the inner padding.
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - Saved episodes

    private var savedEpisodes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Saved episodes", tint: Theme.favorite)
                Spacer()
                Text("\(podcasts.favoriteEpisodes.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }

            LazyVStack(spacing: 2) {
                ForEach(podcasts.favoriteEpisodes) { saved in
                    EpisodeRow(episode: saved.episode, show: saved.show, standalone: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - Chart

    @ViewBuilder
    private var topChart: some View {
        switch chart {
        case .loading:
            StatusPanel(icon: "chart.bar", title: "Loading top podcasts…") {
                ProgressView().tint(Theme.library)
            }

        case .failed(let why):
            StatusPanel(icon: "wifi.exclamationmark", title: "Couldn't load the chart", detail: why, tint: Theme.warn) {
                Button("Retry", action: onRetryChart)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.library)
            }

        case .loaded(let shows):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Top podcasts", tint: Theme.library)
                    Spacer()
                    Text(PodcastCharts.localCountry.uppercased())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                }

                LazyVStack(spacing: 4) {
                    ForEach(Array(shows.enumerated()), id: \.element.id) { offset, show in
                        NavigationLink(value: show) {
                            ShowRow(show: show, rank: offset + 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }
}
