import Foundation

struct TransferItem: Identifiable {
    enum State: Equatable {
        case waiting, copying, done, failed(String), skipped(String)
    }
    let id: String
    let track: Track
    let destinationName: String
    var state: State = .waiting
    var bytesWritten: Int64 = 0

    var progress: Double {
        track.sizeBytes > 0 ? min(1, Double(bytesWritten) / Double(track.sizeBytes)) : 0
    }
}

/// Platform-specific housekeeping around a copy. macOS has real work to do here
/// — suppressing Spotlight, stripping xattrs, sweeping AppleDouble sidecars —
/// while iOS writes through the Files provider and has none of those problems,
/// so it plugs in the no-op.
protocol TransferHygiene: Sendable {
    func prepare(_ volume: URL)
    func afterFile(_ url: URL)
    func finish(_ volume: URL)
}

struct NoHygiene: TransferHygiene {
    func prepare(_ volume: URL) {}
    func afterFile(_ url: URL) {}
    func finish(_ volume: URL) {}
}

/// Cancellation signal readable from the background copy.
///
/// The engine's own `cancelled` flag is main-actor isolated, and the copy no
/// longer runs there, so the two need something they can both touch.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}

/// Byte counter written by the background copy and sampled by the UI.
///
/// Deliberately polled rather than pushed: a 137 MB file is ~550 chunks, and
/// hopping to the main actor for each one would cost more than the copy.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    var bytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func add(_ n: Int64) {
        lock.lock(); value += n; lock.unlock()
    }
}

/// Copies tracks to the device with live progress.
///
/// Deliberately sequential: the link is a ~1.1 MB/s USB full-speed pipe, and
/// interleaving writes on cheap FAT32 flash causes fragmented allocation and
/// extra FAT-table churn, which makes it slower rather than faster.
@MainActor
final class TransferEngine: ObservableObject {
    @Published private(set) var items: [TransferItem] = []
    @Published private(set) var isRunning = false
    @Published private(set) var currentIndex: Int?
    @Published private(set) var bytesDone: Int64 = 0
    @Published private(set) var bytesTotal: Int64 = 0
    @Published private(set) var observedRate: Double = 0
    @Published private(set) var finishedSummary: String?

    private let hygiene: TransferHygiene
    /// Where the last run wrote, kept so a single item can be sent again.
    private var destination: URL?
    private var cancelled = false
    /// Mirrors `cancelled` somewhere the background copy can read it.
    private var cancelFlag = CancelFlag()
    /// 1 MiB. Apple's own copy engine sizes chunks from the volume's
    /// `f_iosize`; on iOS every write to an external drive also crosses into
    /// the user-space FAT driver, so fewer, larger writes cost less. Progress
    /// is sampled on a timer, not per chunk, so the bar stays smooth.
    private let chunkSize = 1_048_576
    /// One quiet retry per file. A single bad write on a cheap flash stick is
    /// common and usually transient; a second failure is reported.
    private let attemptsPerFile = 2

    init(hygiene: TransferHygiene = NoHygiene()) {
        self.hygiene = hygiene
    }

    var overallProgress: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }

    var etaRemaining: String {
        let rate = observedRate > 0 ? observedRate : Theme.measuredWriteBytesPerSec
        return Fmt.clock(Double(bytesTotal - bytesDone) / rate)
    }

    func cancel() {
        cancelled = true
        cancelFlag.set()
    }

    func start(tracks: [Track], destination: URL, numberTracks: Bool, useMetadataNames: Bool) {
        guard !isRunning, !tracks.isEmpty else { return }

        var existing = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
                .map { $0.lowercased() }
        )

        // Continue numbering after whatever is already on the device, so a
        // second batch doesn't restart at 01 and interleave with the first.
        let startIndex = existing.filter { $0.hasSuffix(".mp3") }.count + 1

        items = tracks.enumerated().map { offset, track in
            let name = FileNaming.deviceName(
                for: track,
                index: numberTracks ? startIndex + offset : nil,
                useMetadata: useMetadataNames
            )
            let unique = FileNaming.uniqued(name, existing: existing)
            existing.insert(unique.lowercased())
            return TransferItem(id: track.id, track: track, destinationName: unique)
        }

        self.destination = destination
        bytesTotal = tracks.reduce(0) { $0 + $1.sizeBytes }
        bytesDone = 0
        cancelled = false
        // A fresh flag per run — the old one may still be set from a cancel.
        cancelFlag = CancelFlag()
        isRunning = true
        finishedSummary = nil

        Task { await run(indices: Array(items.indices), overwrite: false) }
    }

    /// Send one item from the last run again, replacing whatever landed.
    ///
    /// Covers both halves of "it didn't take": a copy that failed outright,
    /// and one that reported success but produced a file the player won't
    /// play. The file is rewritten under the same name, so the numbering and
    /// the rest of the batch are untouched.
    func resend(_ itemID: String) {
        guard !isRunning, let destination,
              let index = items.firstIndex(where: { $0.id == itemID }) else { return }

        items[index].state = .waiting
        items[index].bytesWritten = 0
        bytesTotal = items[index].track.sizeBytes
        bytesDone = 0
        cancelled = false
        cancelFlag = CancelFlag()
        isRunning = true
        finishedSummary = nil

        Task { await run(indices: [index], overwrite: true) }
    }

    private func run(indices: [Int], overwrite: Bool) async {
        guard let destination else { isRunning = false; return }
        hygiene.prepare(destination)

        let started = Date()
        var copied = 0, failed = 0, skipped = 0

        for index in indices {
            if cancelled { break }
            currentIndex = index

            let item = items[index]
            let dest = destination.appendingPathComponent(item.destinationName)

            // A half-written file from the previous attempt would otherwise
            // count against the free-space check and then be appended to.
            if overwrite { try? FileManager.default.removeItem(at: dest) }

            // Refuse to start a file that cannot fit; a truncated MP3 on these
            // players shows up as a track that plays for a second and stops.
            // A zero here means the volume didn't report capacity, not that it
            // is full, so the guard only fires on a real number.
            let free = Self.freeBytes(at: destination)
            if free > 0, free < item.track.sizeBytes + 1_048_576 {
                items[index].state = .skipped("not enough free space")
                skipped += 1
                continue
            }

            items[index].state = .copying

            let attempt = await attemptCopy(item: item, to: dest, index: index, startedAt: started)
            switch attempt {
            case .copied:
                hygiene.afterFile(dest)
                items[index].state = .done
                copied += 1
            case .cancelled:
                try? FileManager.default.removeItem(at: dest)
                items[index].state = .skipped("cancelled")
                skipped += 1
            case .failed(let why):
                try? FileManager.default.removeItem(at: dest)
                items[index].state = .failed(why)
                failed += 1
            }
            if case .cancelled = attempt { break }

            // The cable came out: every remaining file would fail the same
            // way, slowly. Say so once and stop.
            if !Self.isReachable(destination) {
                for rest in indices where rest > index && items[rest].state == .waiting {
                    items[rest].state = .skipped("player disconnected")
                    skipped += 1
                }
                if case .failed = items[index].state {
                    items[index].state = .failed("player disconnected")
                }
                break
            }
        }

        // Off the main actor: the settle gap between sidecar passes would
        // otherwise stall the UI for the best part of a second.
        let hygiene = self.hygiene
        await Task.detached { hygiene.finish(destination) }.value

        currentIndex = nil
        isRunning = false

        // Real elapsed time, not floored to a second: flooring made a small
        // file that copied in 200 ms report an alarming 0.04 MB/s.
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        let rateText = Fmt.rate(Double(bytesDone) / elapsed)

        var parts = ["\(copied) transferred"]
        if !cancelled { parts[0] += " in \(Fmt.clock(elapsed)) at \(rateText)" }
        // Skipped and failed are genuinely different outcomes and used to be
        // reported as one number, which made "nothing moved" unreadable.
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        if copied > 0 { parts.append("→ \(destination.lastPathComponent)") }

        finishedSummary = (cancelled ? "Cancelled — " : "") + parts.joined(separator: " · ")
    }

    private enum Attempt {
        case copied, cancelled, failed(String)
    }

    /// One file, with a retry. Cancellation is never retried; a failure is
    /// retried once after a short pause unless the volume itself is gone.
    private func attemptCopy(item: TransferItem, to dest: URL, index: Int, startedAt: Date) async -> Attempt {
        var lastFailure = "unknown error"
        let doneBefore = bytesDone
        for attempt in 1...attemptsPerFile {
            do {
                try await copy(from: item.track.url, to: dest, itemIndex: index, startedAt: startedAt)
                return .copied
            } catch is CancellationError {
                return .cancelled
            } catch {
                lastFailure = error.localizedDescription
                try? FileManager.default.removeItem(at: dest)
                guard attempt < attemptsPerFile, Self.isReachable(dest.deletingLastPathComponent()) else { break }
                // Wind the totals back so the bar doesn't jump past 100%.
                items[index].bytesWritten = 0
                bytesDone = doneBefore
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if cancelled { return .cancelled }
            }
        }
        return .failed(lastFailure)
    }

    /// Whether the destination folder still exists. On iOS an unplugged
    /// drive's mount point simply vanishes; nothing announces it.
    private nonisolated static func isReachable(_ folder: URL) -> Bool {
        (try? folder.checkResourceIsReachable()) ?? false
    }

    /// Runs one file's copy on a background thread and samples its progress.
    ///
    /// The copy used to run here on the main actor, yielding between chunks to
    /// let SwiftUI repaint. That was survivable on macOS but wrong on iOS: the
    /// writes land in the file provider's buffer almost instantly — so the bar
    /// races to 100% — and then `synchronize()` blocks for as long as it takes
    /// the bytes to actually reach the device. On a 137 MB episode over a
    /// ~1 MB/s link that is more than two minutes of frozen UI, which reads as
    /// a transfer that finished and then hung.
    private func copy(from src: URL, to dest: URL, itemIndex: Int, startedAt: Date) async throws {
        let box = ProgressBox()
        let flag = cancelFlag
        let chunk = chunkSize
        let expected = items[itemIndex].track.sizeBytes
        let base = bytesDone

        let work = Task.detached(priority: .utility) {
            try Self.streamCopy(
                from: src, to: dest, expected: expected,
                chunkSize: chunk, cancel: flag, progress: box
            )
        }

        // Sample the counter instead of having the copy push every chunk at us;
        // the UI only needs a few updates a second.
        let poller = Task { @MainActor [weak self] in
            while true {
                // A cancelled sleep must exit here, not fall through to one
                // last write: the retry path resets the totals right after
                // this task is cancelled and a stale tick would undo that.
                do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
                guard let self, self.items.indices.contains(itemIndex) else { return }
                let n = box.bytes
                self.items[itemIndex].bytesWritten = n
                self.bytesDone = base + n
                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed > 0.5 { self.observedRate = Double(self.bytesDone) / elapsed }
            }
        }

        do {
            try await work.value
        } catch {
            poller.cancel()
            await poller.value
            throw error
        }
        poller.cancel()
        await poller.value

        // Land on the exact totals; the last poll almost never coincides with
        // the final chunk.
        items[itemIndex].bytesWritten = expected
        bytesDone = base + expected
    }

    /// The actual copy. `nonisolated` and `static` so it cannot accidentally
    /// touch main-actor state — every byte of this runs off the main thread.
    private nonisolated static func streamCopy(
        from src: URL, to dest: URL, expected: Int64,
        chunkSize: Int, cancel: CancelFlag, progress: ProgressBox
    ) throws {
        // Sources handed over by a document picker are security-scoped; opening
        // them without claiming the scope first fails with a permission error.
        // Harmless on macOS, where local library files are not scoped.
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }

        // `createFile` returns false when the destination can't be written —
        // ignoring it turned a permission problem into a confusing "could not
        // create file" further down, or worse, a silent no-op.
        guard FileManager.default.createFile(atPath: dest.path, contents: nil),
              let output = try? FileHandle(forWritingTo: dest) else {
            throw NSError(domain: "SwimSync", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "couldn't create a file in \(dest.deletingLastPathComponent().lastPathComponent)"
            ])
        }

        // Closed explicitly before the size is read, so `defer` must not close
        // it a second time — a double close raises rather than throwing.
        var isOpen = true
        defer { if isOpen { try? output.close() } }

        while true {
            if cancel.isSet { throw CancellationError() }

            guard let bytes = try input.read(upToCount: chunkSize), !bytes.isEmpty else { break }
            try output.write(contentsOf: bytes)
            progress.add(Int64(bytes.count))
        }

        // Blocking, and sometimes for a long time — which is precisely why it
        // belongs here rather than on the main actor.
        try output.synchronize()
        try output.close()
        isOpen = false

        // Trust the filesystem, not the write calls. On a FAT32 stick behind a
        // slow link — and especially behind an iOS file provider — a write can
        // report success and still land short. Reporting a truncated file as
        // "transferred" is the worst possible outcome: the player shows a track
        // that plays for a second and stops.
        let landed = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard landed == expected else {
            throw NSError(domain: "SwimSync", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "only \(Fmt.bytes(landed)) of \(Fmt.bytes(expected)) landed"
            ])
        }
    }

    private static func freeBytes(at volume: URL) -> Int64 {
        let v = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(v?.volumeAvailableCapacity ?? 0)
    }

    func reset() {
        guard !isRunning else { return }
        items = []
        bytesDone = 0
        bytesTotal = 0
        observedRate = 0
        finishedSummary = nil
    }
}
