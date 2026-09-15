import SwiftUI

/// Search Apple's podcast directory — by show or by episode — then drill into
/// a show. With nothing typed it browses instead: favourites, history, and the
/// top chart.
///
/// Everywhere else the app can only work with audio the user already has on the
/// phone; this is the one screen that can fetch new audio by itself. Because a
/// search can fail four different ways (nothing typed, still running, no
/// matches, network error) and each one otherwise looks identical — an empty
/// list — every state below is drawn explicitly. There is deliberately no code
/// path here that renders nothing.
struct DiscoverView: View {
    @State private var term = ""
    @State private var mode: Mode = .shows
    @State private var searchState: SearchState = .idle
    @State private var chart: ChartState = .loading

    /// The in-flight search, held so a new submit cancels the previous one. A
    /// slow response to an older term would otherwise land last and overwrite
    /// the results the user is currently looking at.
    @State private var inFlight: Task<Void, Never>?

    /// The term the current results or error belong to. Retry re-runs *that*
    /// search rather than whatever happens to be in the field by then.
    @State private var submitted = ""

    enum Mode: String, CaseIterable, Identifiable {
        case shows = "Shows", episodes = "Episodes"
        var id: String { rawValue }
    }

    enum SearchState {
        case idle
        case searching
        case shows([PodcastShow])
        case episodes([EpisodeHit])
        case noMatches(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    searchField
                    modePicker
                    content
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Find")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PodcastShow.self) { show in
                ShowDetailView(show: show)
            }
            .task { await loadChart() }
            .onChange(of: mode) { _, _ in
                // Switching Shows ↔ Episodes re-asks the same question in the
                // new shape rather than leaving stale results under a
                // picker that now says otherwise.
                if !submitted.isEmpty { run(submitted) }
            }
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textFaint)

            TextField(mode == .shows ? "Search shows" : "Search episodes", text: $term)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { run(term) }

            if !term.isEmpty {
                Button {
                    term = ""
                    submitted = ""
                    inFlight?.cancel()
                    searchState = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }

    private var modePicker: some View {
        Picker("Search for", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch searchState {
        case .idle:
            BrowseSections(chart: chart, onRetryChart: { Task { await loadChart() } })
        case .searching:
            StatusPanel(icon: "waveform.badge.magnifyingglass", title: "Searching…") {
                ProgressView().tint(Theme.library)
            }
        case .shows(let shows):
            showList(shows)
        case .episodes(let hits):
            episodeList(hits)
        case .noMatches(let what):
            StatusPanel(
                icon: "magnifyingglass",
                title: mode == .shows ? "No shows named “\(what)”" : "No episodes matching “\(what)”",
                detail: mode == .shows
                    ? "Try the show's exact name, or the host's name."
                    : "Try a word from the episode title, or switch to Shows and browse the feed."
            )
        case .failed(let why):
            StatusPanel(icon: "wifi.exclamationmark", title: "Search failed", detail: why, tint: Theme.warn) {
                Button("Retry") { run(submitted) }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.library)
            }
        }
    }

    private func showList(_ shows: [PodcastShow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Shows", tint: Theme.library)
                Spacer()
                Text("\(shows.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }

            LazyVStack(spacing: 4) {
                ForEach(shows) { show in
                    NavigationLink(value: show) {
                        ShowRow(show: show)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func episodeList(_ hits: [EpisodeHit]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Episodes", tint: Theme.library)
                Spacer()
                Text("\(hits.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }

            Text("Tap a title to see the whole show.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)

            LazyVStack(spacing: 2) {
                ForEach(hits) { hit in
                    EpisodeRow(episode: hit.episode, show: hit.show, standalone: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - Running the search

    private func run(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchState = .idle
            return
        }

        inFlight?.cancel()
        submitted = trimmed
        searchState = .searching
        let mode = self.mode

        inFlight = Task {
            do {
                let result: SearchState
                switch mode {
                case .shows:
                    let shows = try await PodcastDirectory.search(trimmed)
                    result = shows.isEmpty ? .noMatches(trimmed) : .shows(shows)
                case .episodes:
                    let hits = try await PodcastDirectory.searchEpisodes(trimmed)
                    result = hits.isEmpty ? .noMatches(trimmed) : .episodes(hits)
                }
                // A cancelled task's result belongs to a term the user has
                // already moved on from — dropping it is the whole point.
                guard !Task.isCancelled else { return }
                searchState = result
            } catch {
                guard !Task.isCancelled else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func loadChart() async {
        chart = .loading
        do {
            let shows = try await PodcastCharts.top()
            chart = shows.isEmpty ? .failed("The chart came back empty.") : .loaded(shows)
        } catch {
            chart = .failed(error.localizedDescription)
        }
    }
}
