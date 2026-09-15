import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var monitor: DeviceMonitor
    @EnvironmentObject var transfer: TransferEngine

    @State private var tab: SourceKind = .podcasts
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var isDropTarget = false
    @State private var numberTracks = true
    @State private var useMetadataNames = true
    @State private var hideOnDevice = true
    @State private var playableOnly = true

    private var deviceIndex: DeviceIndex { monitor.contents.indexed }

    /// One shelf after every active filter. Search is deliberately optional:
    /// the displayed list applies it, but the transfer queue must not, or
    /// typing in the box would silently drop tracks queued on another tab.
    private func filtered(_ kind: SourceKind, index: DeviceIndex, applySearch: Bool) -> [Track] {
        var tracks = library.tracks(for: kind)

        if playableOnly {
            tracks = tracks.filter { $0.isLikelyPlayable }
        }
        if hideOnDevice, !index.isEmpty {
            tracks = tracks.filter { !index.contains($0) }
        }
        if applySearch, !search.isEmpty {
            tracks = tracks.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(search)
                    || $0.displayShow.localizedCaseInsensitiveContains(search)
                    || $0.displayAlbum.localizedCaseInsensitiveContains(search)
                    || $0.filename.localizedCaseInsensitiveContains(search)
            }
        }
        return tracks
    }

    /// How many tracks on this shelf the player already has — the number the
    /// "hide" chip reports, so it stays truthful whether the chip is on or off.
    private func onDeviceCount(_ kind: SourceKind, index: DeviceIndex) -> Int {
        guard !index.isEmpty else { return 0 }
        return library.tracks(for: kind).filter { index.contains($0) }.count
    }

    /// The queue, gathered across every shelf so podcasts and music can go over
    /// in one pass. DRM-protected files can never be copied usefully, so they
    /// are excluded even if somehow selected.
    private func selectedTracks(index: DeviceIndex) -> [Track] {
        SourceKind.allCases
            .flatMap { filtered($0, index: index, applySearch: false) }
            .filter { selection.contains($0.id) && !$0.isDRMProtected }
    }

    var body: some View {
        let index = deviceIndex
        let visible = filtered(tab, index: index, applySearch: true)
        let selected = selectedTracks(index: index)

        return HStack(spacing: 0) {
            LibraryPane(
                tab: $tab,
                tracks: visible,
                selection: $selection,
                search: $search,
                isScanning: library.isScanning,
                onDeviceCount: onDeviceCount(tab, index: index),
                hiddenFormatCount: hiddenFormatCount,
                hideOnDevice: $hideOnDevice,
                playableOnly: $playableOnly,
                isOnDevice: { index.contains($0) }
            )
            .frame(minWidth: 480)

            Divider().overlay(Theme.hairline)

            DevicePane(
                selectedCount: selected.count,
                selectedBytes: selected.reduce(0) { $0 + $1.sizeBytes },
                numberTracks: $numberTracks,
                useMetadataNames: $useMetadataNames,
                onTransfer: { startTransfer(selected) }
            )
            .frame(width: 380)
        }
        .background(Theme.bg)
        .overlay(alignment: .top) {
            if isDropTarget { dropOverlay }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
            return true
        }
        .onReceive(monitor.didAttach) { _ in
            // Bring the window forward when the player is plugged in.
            NSApp.activate(ignoringOtherApps: true)
        }
        .onChange(of: transfer.isRunning) { was, now in
            // Re-read the device the moment a transfer ends, so the freshly
            // copied tracks drop out of the library list straight away.
            if was, !now { monitor.refresh() }
        }
    }

    /// Tracks on this shelf the format filter is holding back.
    private var hiddenFormatCount: Int {
        guard playableOnly else { return 0 }
        return library.tracks(for: tab).filter { !$0.isLikelyPlayable }.count
    }

    private var dropOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.library)
            Text("Drop audio files or a folder")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.opacity(0.92))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous)
                .strokeBorder(Theme.library.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(14)
        )
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                guard let item = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) else { continue }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            await MainActor.run {
                library.addDropped(urls)
                tab = .files
            }
        }
    }

    private func startTransfer(_ tracks: [Track]) {
        guard let device = monitor.device, !tracks.isEmpty else { return }
        transfer.start(
            tracks: tracks,
            destination: device.volume,
            numberTracks: numberTracks,
            useMetadataNames: useMetadataNames
        )
        selection.removeAll()
    }
}
