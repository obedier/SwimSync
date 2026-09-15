import SwiftUI

/// The phone's Music library, one row per song, with a convert-and-queue
/// control in the place the podcast rows keep their download button.
struct MusicView: View {
    @EnvironmentObject var music: MusicLibrarySource
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if music.isAuthorized {
                    songList
                } else {
                    permission
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if music.isAuthorized {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { music.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(music.isLoading)
                    }
                }
            }
        }
        .task { await music.requestAccess() }
        .alert("Something went wrong", isPresented: problemBinding) {
            Button("OK") { music.problem = nil }
        } message: {
            Text(music.problem ?? "")
        }
    }

    private var problemBinding: Binding<Bool> {
        Binding(get: { music.problem != nil }, set: { if !$0 { music.problem = nil } })
    }

    // MARK: - Permission

    private var permission: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(Theme.music)
            Text(music.authorization == .notDetermined ? "Your music, on the player" : "Music access is off")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(music.authorization == .notDetermined
                 ? "SwimSync can convert songs from this iPhone's library into MP3s for the player. Apple Music subscription tracks are copy-protected and can't be copied."
                 : "Allow Media & Apple Music for SwimSync in Settings to list your songs.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            if music.authorization == .notDetermined {
                Button("Allow access") { Task { await music.requestAccess() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.music)
            } else if let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settings)
                    .buttonStyle(.bordered)
                    .tint(Theme.music)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Songs

    private var filtered: [LibrarySong] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return music.songs }
        return music.songs.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
    }

    /// Artist → songs, in the order the source already sorted them.
    private var grouped: [(artist: String, songs: [LibrarySong])] {
        var order: [String] = []
        var buckets: [String: [LibrarySong]] = [:]
        for song in filtered {
            if buckets[song.artist] == nil { order.append(song.artist) }
            buckets[song.artist, default: []].append(song)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var songList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if music.songs.isEmpty {
                    emptyState
                } else {
                    summary
                    ForEach(grouped, id: \.artist) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: group.artist, tint: Theme.music)
                                .padding(.horizontal, 4)
                            ForEach(group.songs) { song in
                                MusicRow(song: song)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel()
                    }
                }
            }
            .padding(16)
        }
        .searchable(text: $query, prompt: "Song, artist or album")
        .refreshable { music.reload() }
    }

    private var summary: some View {
        let exportable = music.songs.filter(\.isExportable).count
        let locked = music.songs.count - exportable
        return Text(locked == 0
                    ? "\(music.songs.count) songs"
                    : "\(exportable) of \(music.songs.count) songs can be copied · \(locked) are Apple Music or not downloaded")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if music.isLoading {
                ProgressView().tint(Theme.music)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(Theme.textFaint)
                Text("No songs in the Music library")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                Text("Songs synced from a Mac or bought from the iTunes Store show up here. Apple Music streaming tracks can't be copied.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// One song: title, album and length, and the convert control.
struct MusicRow: View {
    let song: LibrarySong
    @EnvironmentObject var music: MusicLibrarySource

    private var isReady: Bool { music.localURL(for: song) != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(song.isExportable ? Theme.text : Theme.textFaint)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                    if let reason = song.unavailableReason {
                        TrackBadge(text: reason, tint: Theme.warn)
                    } else if isReady {
                        TrackBadge(text: "on phone", tint: Theme.ok)
                    }
                }
            }

            Spacer(minLength: 4)

            control.frame(width: 30, height: 30)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isReady ? Color.white.opacity(0.03) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
    }

    private var detail: String {
        var parts: [String] = []
        if !song.album.isEmpty { parts.append(song.album) }
        if song.duration > 0 { parts.append(Fmt.duration(song.duration)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var control: some View {
        if isReady {
            Button { music.export(song) } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.ok)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Converted — tap to queue again")
        } else if music.isExporting(song) {
            Button { music.cancel(song) } label: {
                DownloadRing(progress: music.progress[song.id] ?? 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
        } else if song.isExportable {
            Button { music.export(song) } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.music)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Convert to MP3 and queue")
        } else {
            Image(systemName: "lock.circle")
                .font(.system(size: 19))
                .foregroundStyle(Theme.textFaint.opacity(0.6))
        }
    }
}
