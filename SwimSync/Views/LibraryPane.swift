import SwiftUI
import AppKit

struct LibraryPane: View {
    @Binding var tab: SourceKind
    let tracks: [Track]
    @Binding var selection: Set<String>
    @Binding var search: String
    let isScanning: Bool
    let onDeviceCount: Int
    let hiddenFormatCount: Int
    @Binding var hideOnDevice: Bool
    @Binding var playableOnly: Bool
    let isOnDevice: (Track) -> Bool

    @EnvironmentObject var library: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            if let denied = library.accessDenied, denied.kind == tab {
                accessBanner(denied)
            }

            if tracks.isEmpty {
                emptyState
            } else if tab == .music {
                groupedList
            } else {
                flatList
            }

            Divider().overlay(Theme.hairline)
            footer
        }
        .background(Theme.surface.opacity(0.35))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                tabBar
                if isScanning {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                Spacer()
                sourcesMenu
            }

            Text(sourceSummary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)

            searchField

            if onDeviceCount > 0 || hiddenFormatCount > 0 || !playableOnly {
                chips
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 13)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SourceKind.allCases) { kind in
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { tab = kind }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: kind.icon).font(.system(size: 10, weight: .semibold))
                        Text(kind.title).font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(tab == kind ? kind.tint : Theme.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tab == kind ? kind.tint.opacity(0.14) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.bg.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }

    private var sourcesMenu: some View {
        Menu {
            ForEach(library.sources(for: tab)) { source in
                Button("Remove \(source.displayName)") { library.removeSource(source) }
            }
            Divider()
            Button("Add Folder to \(tab.title)…") { pickFolder() }
            if tab == .files, !library.dropped.isEmpty {
                Button("Clear Dropped Files") { library.clearDropped() }
            }
        } label: {
            Label("Sources", systemImage: "folder.badge.plus")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(Theme.textDim)
    }

    private var sourceSummary: String {
        let names = library.sources(for: tab).map(\.displayName)
        if names.isEmpty {
            return tab == .files ? "Drop files here, or add a folder" : "No folder added yet"
        }
        return names.joined(separator: " · ")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textFaint)
            TextField(tab == .music ? "Filter songs" : "Filter episodes", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if onDeviceCount > 0 {
                FilterChip(
                    label: "\(onDeviceCount) already on player",
                    icon: "eye.slash.fill",
                    tint: Theme.ok,
                    isOn: $hideOnDevice
                )
                .help(hideOnDevice ? "Hidden — click to show them" : "Shown — click to hide them")
            }
            if hiddenFormatCount > 0 || !playableOnly {
                FilterChip(
                    label: playableOnly ? "MP3 and WAV only" : "All formats",
                    icon: "waveform",
                    tint: Theme.warn,
                    isOn: $playableOnly
                )
                .help("The player decodes MP3 and WAV; other formats copy but may not play")
            }
            Spacer()
        }
    }

    // MARK: - Lists

    private var flatList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    row(track)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// Music is browsed by artist, so the flat recency list that suits podcasts
    /// is replaced by sticky artist sections.
    private var groupedList: some View {
        ScrollView {
            LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(grouped, id: \.artist) { group in
                    Section {
                        ForEach(group.tracks) { track in
                            row(track)
                        }
                    } header: {
                        HStack {
                            Text(group.artist)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .tracking(0.8)
                                .foregroundStyle(Theme.music)
                            Spacer()
                            Text("\(group.tracks.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textFaint)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.bg.opacity(0.96))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var grouped: [(artist: String, tracks: [Track])] {
        var order: [String] = []
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            let key = track.groupingArtist
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(track)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private func row(_ track: Track) -> some View {
        TrackRow(
            track: track,
            isSelected: selection.contains(track.id),
            isOnDevice: isOnDevice(track),
            tint: tab.tint,
            toggle: { toggle(track) }
        )
    }

    // MARK: - Empty & banners

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: tab == .music ? "music.note.list" : "waveform")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Theme.textFaint)
            Text(emptyTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textDim)
            Text(emptyHint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !search.isEmpty { return "No matches" }
        if onDeviceCount > 0 && hideOnDevice { return "Everything here is on the player" }
        return tab == .music ? "No music found" : "Nothing to transfer"
    }

    private var emptyHint: String {
        if !search.isEmpty { return "Try a different search." }
        if onDeviceCount > 0 && hideOnDevice {
            return "All \(onDeviceCount) tracks have already been transferred. Click the chip above to show them."
        }
        if hiddenFormatCount > 0 {
            return "\(hiddenFormatCount) file\(hiddenFormatCount == 1 ? " is" : "s are") in a format the player may not decode. Click “MP3 and WAV only” to show them."
        }
        return "Drop files anywhere, or add a folder."
    }

    private func accessBanner(_ source: Source) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS is blocking \(source.displayName)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Grant access once and it's remembered.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button("Grant…") { pickFolder(startingAt: source.url) }
                .buttonStyle(PillButton(tint: Theme.warn))
        }
        .padding(12)
        .background(Theme.warn.opacity(0.10))
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }

    private var footer: some View {
        HStack {
            Text("\(tracks.count) \(tab == .music ? "song" : "episode")\(tracks.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
            Spacer()
            Button(allSelected ? "Deselect All" : "Select All") {
                let ids = tracks.filter { !$0.isDRMProtected }.map(\.id)
                if allSelected {
                    ids.forEach { selection.remove($0) }
                } else {
                    ids.forEach { selection.insert($0) }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tab.tint)
            .disabled(tracks.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }

    /// Only considers the shelf on screen, so "Select All" on Music doesn't
    /// claim to have deselected a podcast queue.
    private var allSelected: Bool {
        let ids = tracks.filter { !$0.isDRMProtected }.map(\.id)
        return !ids.isEmpty && ids.allSatisfy { selection.contains($0) }
    }

    private func toggle(_ track: Track) {
        if selection.contains(track.id) { selection.remove(track.id) }
        else { selection.insert(track.id) }
    }

    private func pickFolder(startingAt: URL? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to add to \(tab.title)"
        panel.prompt = "Use Folder"
        if let startingAt { panel.directoryURL = startingAt }
        if panel.runModal() == .OK, let url = panel.url {
            library.addSource(url, kind: tab)
        }
    }
}
