import SwiftUI
import UniformTypeIdentifiers

struct TransferView: View {
    @EnvironmentObject var drive: DriveStore
    @EnvironmentObject var library: MobileLibrary
    @EnvironmentObject var transfer: TransferEngine
    @EnvironmentObject var inbox: Inbox

    @Environment(\.scenePhase) private var scenePhase
    @State private var picking = false
    @State private var pickerMode: PickerMode = .drive
    @State private var numberTracks = true
    @State private var useMetadataNames = true
    @State private var skipDuplicates = true
    @State private var sending: Set<String> = []
    /// Queued tracks the player already has that the user wants replaced.
    @State private var forced: Set<String> = []
    @State private var confirmingErase = false
    /// True from the tap until the engine reports itself running. The
    /// replace-in-place deletes happen in that gap, and the engine's own
    /// flag can't cover it, so the button is disabled from here instead.
    @State private var starting = false

    /// What will actually be sent. Duplicates and copy-protected files are
    /// filtered here rather than at the point of copy, so the count on the
    /// button is the truth. A forced track goes regardless of duplicates.
    private var sendable: [Track] {
        let index = drive.index
        return library.queue.filter { track in
            guard !track.isDRMProtected else { return false }
            if forced.contains(track.id) { return true }
            return !(skipDuplicates && index.contains(track))
        }
    }

    private var duplicateCount: Int {
        let index = drive.index
        return library.queue.filter { index.contains($0) }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    PlayerCard(onChoose: { present(.drive) }, onErase: { confirmingErase = true })

                    QueueCard(
                        sendable: Set(sendable.map(\.id)),
                        forced: forced,
                        isOnDrive: { drive.index.contains($0) },
                        onAdd: { present(.files) },
                        onToggleForce: { toggleForce($0) }
                    )

                    if !library.queue.isEmpty { options }

                    if transfer.isRunning || transfer.finishedSummary != nil {
                        TransferPanel(onResend: { transfer.resend($0.id) })
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("SwimSync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add Files…") { present(.files) }
                        Button("Read a Text File Aloud…") { present(.text) }
                        Button(drive.isConnected ? "Change Player Folder…" : "Choose Player Folder…") {
                            present(.drive)
                        }
                        if drive.isConnected {
                            Button("Refresh") { drive.refresh() }
                            if drive.isExternal && !drive.contents.isEmpty {
                                Button("Erase Player…", role: .destructive) { confirmingErase = true }
                            }
                            Button("Forget Player", role: .destructive) { drive.forget() }
                        }
                        if !library.queue.isEmpty {
                            Button("Clear Queue", role: .destructive) { library.clear() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { transferBar }
            .onChange(of: transfer.isRunning) { was, now in
                if was, !now { finish() }
            }
            // Plugging the player in while the app is backgrounded is the
            // normal case, so re-attach on every return to the foreground
            // rather than only at launch.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { drive.reconnectIfNeeded() }
            }
        }
        // Exactly one importer. Two `.fileImporter` modifiers on the same view
        // conflict in SwiftUI — the later one wins, so asking for a folder
        // silently opened the audio-file picker and the USB drive never
        // appeared. The mode is held in its own state that the presentation
        // binding never clears, so the completion handler can always tell which
        // picker it is answering for.
        .fileImporter(
            isPresented: $picking,
            allowedContentTypes: pickerMode.contentTypes,
            allowsMultipleSelection: pickerMode == .files
        ) { result in
            handlePick(result)
        }
        .alert("Something went wrong", isPresented: problemBinding) {
            Button("OK") { drive.problem = nil; library.problem = nil }
        } message: {
            Text(drive.problem ?? library.problem ?? "")
        }
        .confirmationDialog(
            "Erase \(drive.contents.count) track\(drive.contents.count == 1 ? "" : "s") from the player?",
            isPresented: $confirmingErase,
            titleVisibility: .visible
        ) {
            Button("Erase \(drive.contents.count) track\(drive.contents.count == 1 ? "" : "s")", role: .destructive) {
                Task { await drive.eraseAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every audio file in \(drive.destinationDescription). Nothing else on the drive is touched, and downloads on this iPhone are kept. This can't be undone.")
        }
    }

    enum PickerMode {
        case drive, files, text

        var contentTypes: [UTType] {
            switch self {
            case .drive: return [.folder]
            case .files: return [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
            case .text: return Inbox.textTypes
            }
        }
    }

    private func present(_ mode: PickerMode) {
        pickerMode = mode
        picking = true
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            // Previously swallowed, which made a failed pick look like an empty
            // drive rather than an error.
            drive.problem = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            // Trust the shape of what came back over the mode flag: a folder
            // is the player no matter which button opened the picker.
            if urls.count == 1, urls[0].hasDirectoryPath {
                drive.choose(urls[0])
            } else if pickerMode == .text {
                // One at a time: each becomes its own recording.
                inbox.receive(urls[0], into: library)
            } else {
                library.add(urls)
            }
        }
    }

    private var problemBinding: Binding<Bool> {
        Binding(
            get: { drive.problem != nil || library.problem != nil },
            set: { if !$0 { drive.problem = nil; library.problem = nil } }
        )
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "On transfer")

            Toggle(isOn: $numberTracks) {
                optionLabel(
                    "Number tracks in order",
                    "These players sort by filename, so “01 - ” keeps your order."
                )
            }
            Toggle(isOn: $useMetadataNames) {
                optionLabel(
                    "Name from tags",
                    "Replaces meaningless filenames with the real title."
                )
            }
            if duplicateCount > 0 {
                Toggle(isOn: $skipDuplicates) {
                    optionLabel(
                        "Skip \(duplicateCount) already on player",
                        "Matched by name and exact size."
                    )
                }
            }
        }
        .tint(Theme.accent)
        .foregroundStyle(Theme.text)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func optionLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bottom bar

    private var transferBar: some View {
        VStack(spacing: 8) {
            if !sendable.isEmpty && !transfer.isRunning {
                HStack {
                    Text("\(sendable.count) to send · \(Fmt.bytes(sendable.reduce(0) { $0 + $1.sizeBytes }))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Text("~\(Fmt.eta(bytes: sendable.reduce(0) { $0 + $1.sizeBytes }))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }
            }

            if transfer.isRunning {
                Button("Cancel") { transfer.cancel() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.warn.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
            } else {
                Button(action: start) {
                    Text(sendable.isEmpty
                         ? "Nothing to send"
                         : "Send \(sendable.count) to \(drive.isExternal ? "player" : "this iPhone")")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSend ? .black.opacity(0.88) : Theme.textFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(canSend ? Theme.accent : Theme.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        drive.isConnected && !sendable.isEmpty && !transfer.isRunning && !starting
    }

    private func toggleForce(_ track: Track) {
        forced = forced.symmetricDifference([track.id])
    }

    private func start() {
        guard let volume = drive.device?.volume, canSend else { return }
        starting = true
        let tracks = sendable
        sending = Set(tracks.map(\.id))

        // A forced track replaces what it matched: the old copies come off
        // first so the new one lands under a clean name instead of " (2)".
        let index = drive.index
        let stale = tracks
            .filter { forced.contains($0.id) }
            .flatMap { index.matchingNames(for: $0) }
        let doomed = drive.tracks(named: stale)

        Task {
            await drive.remove(doomed)
            transfer.start(
                tracks: tracks,
                destination: volume,
                numberTracks: numberTracks,
                useMetadataNames: useMetadataNames
            )
            starting = false
        }
    }

    /// Drop what was just sent off the queue and re-read the drive, so the
    /// screen reflects the player rather than what the user asked for.
    private func finish() {
        library.removeAll { sending.contains($0.id) }
        forced.subtract(sending)
        sending = []
        drive.refresh()
        drive.dumpVolumeDiagnostics()
    }
}
