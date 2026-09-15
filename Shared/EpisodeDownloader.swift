import Foundation

/// Downloads podcast episodes into the app's Documents folder so they can be
/// queued for transfer like any other local file.
///
/// Uses `URLSessionDownloadTask` rather than `data(from:)` for two reasons that
/// matter here: episodes are 30–150 MB, so streaming to a temp file instead of
/// holding the whole body in memory is the difference between working and being
/// jetsammed on a phone; and the download delegate is the only API that reports
/// real byte progress.
@MainActor
final class EpisodeDownloader: ObservableObject {
    /// Episode id → 0...1. Absent once a download finishes, fails, or is
    /// cancelled, so the UI can key "in flight" off membership alone.
    @Published private(set) var progress: [String: Double] = [:]

    /// Episode id → the finished file on disk.
    @Published private(set) var completed: [String: URL] = [:]

    /// Last user-facing failure. Writable so a view can dismiss it.
    @Published var problem: String?

    /// Called on the main actor as each file lands, so the app can add it to
    /// the transfer queue without polling `completed`. The show is whichever
    /// one the episode was requested from — nil for an episode that arrived
    /// without one, which only a future caller could produce.
    var onComplete: ((FeedEpisode, PodcastShow?, URL) -> Void)?

    private struct Job {
        let episode: FeedEpisode
        let show: PodcastShow?
        let destination: URL
        /// Candidate URLs not yet tried — see `FeedParser.candidates(for:)`.
        var remaining: [URL]
        var task: URLSessionDownloadTask?
    }

    private var jobs: [String: Job] = [:]
    private let delegate = DownloadDelegate()
    private let session: URLSession

    init() {
        // A serial delegate queue keeps callbacks for a single task in order;
        // the delegate's own state is additionally lock-guarded because
        // registration happens on the main actor, off this queue.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
        delegate.owner = self
    }

    /// `Documents/Episodes`, created the first time it is asked for.
    ///
    /// Documents rather than Caches deliberately: the system may evict Caches
    /// under disk pressure, and losing a 100 MB download the user is about to
    /// copy to a device is exactly the wrong moment for that.
    var downloadsFolder: URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let folder = documents.appendingPathComponent("Episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func isDownloading(_ episode: FeedEpisode) -> Bool { jobs[episode.id] != nil }

    /// The finished file, or nil. Checks the filesystem rather than only the
    /// published dictionary so downloads from a previous launch are recognised.
    func localURL(for episode: FeedEpisode) -> URL? {
        if let known = completed[episode.id],
           FileManager.default.fileExists(atPath: known.path) { return known }
        let candidate = destination(for: episode)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func download(_ episode: FeedEpisode, from show: PodcastShow? = nil) {
        guard jobs[episode.id] == nil else { return }

        // Already on disk — from an earlier session, or a re-tap. Report it as
        // finished immediately so the caller's queueing path is identical.
        if let existing = localURL(for: episode) {
            markComplete(episode, from: show, at: existing)
            return
        }

        let job = Job(
            episode: episode,
            show: show,
            destination: destination(for: episode),
            remaining: FeedParser.candidates(for: episode.audioURL),
            task: nil
        )
        jobs[episode.id] = job
        progress[episode.id] = 0
        startNextAttempt(for: episode.id, failure: nil)
    }

    /// Cancels and forgets the download. Deliberately silent: the user asked
    /// for this, so it is not a problem worth surfacing.
    func cancel(_ episode: FeedEpisode) {
        guard let job = jobs.removeValue(forKey: episode.id) else { return }
        progress[episode.id] = nil
        job.task?.cancel()
    }

    // MARK: - Attempts

    /// Starts the next candidate URL, or gives up and reports `failure`.
    ///
    /// Plain-http enclosures are still common, and App Transport Security
    /// blocks them, so the https upgrade is tried first and the original kept
    /// as a fallback for hosts with no TLS listener.
    private func startNextAttempt(for episodeID: String, failure: String?) {
        guard var job = jobs[episodeID] else { return }

        guard !job.remaining.isEmpty else {
            jobs[episodeID] = nil
            progress[episodeID] = nil
            problem = "Could not download “\(job.episode.title)” — \(failure ?? "no usable address")."
            return
        }

        let url = job.remaining.removeFirst()
        let task = session.downloadTask(with: url)
        job.task = task
        jobs[episodeID] = job

        delegate.register(task: task.taskIdentifier, episode: episodeID, destination: job.destination)
        task.resume()
    }

    // MARK: - Delegate callbacks (main actor)

    fileprivate func report(_ fraction: Double, for episodeID: String, task: Int) {
        guard jobs[episodeID]?.task?.taskIdentifier == task else { return }
        progress[episodeID] = fraction
    }

    /// Terminal callback for one attempt. `cancelled` downloads leave no trace;
    /// a failure retries the next candidate URL before surfacing anything.
    ///
    /// The task identifier is checked rather than the episode alone: cancelling
    /// and immediately re-requesting the same episode leaves the old task's
    /// callback still in flight, and without this it would tear down the new
    /// job a moment after it started.
    fileprivate func finish(episodeID: String, task: Int, fileURL: URL?,
                            failure: String?, cancelled: Bool) {
        guard let job = jobs[episodeID], job.task?.taskIdentifier == task else { return }

        if cancelled {
            jobs[episodeID] = nil
            progress[episodeID] = nil
            return
        }

        if let fileURL {
            jobs[episodeID] = nil
            markComplete(job.episode, from: job.show, at: fileURL)
            return
        }

        startNextAttempt(for: episodeID, failure: failure)
    }

    private func markComplete(_ episode: FeedEpisode, from show: PodcastShow?, at url: URL) {
        progress[episode.id] = nil
        completed[episode.id] = url
        onComplete?(episode, show, url)
    }

    // MARK: - Naming

    /// The player shows raw filenames, so this is the whole on-device
    /// experience for a downloaded episode — hence show and title, not a guid.
    private func destination(for episode: FeedEpisode) -> URL {
        var stem = FileNaming.sanitize("\(episode.showTitle) - \(episode.title)")

        // HFS+/APFS allow 255 bytes per component and FAT32 the same, but a
        // multi-byte title can blow past that well before 255 characters.
        let cap = 120
        if stem.count > cap {
            stem = String(stem.prefix(cap)).trimmingCharacters(in: .whitespaces)
        }

        let raw = episode.audioURL.pathExtension.lowercased()
        let ext = FeedParser.audioExtensions.contains(raw) ? raw : "mp3"
        return downloadsFolder.appendingPathComponent("\(stem).\(ext)")
    }
}

// MARK: - URLSession delegate

/// `URLSession` needs an `NSObject` delegate, and its callbacks arrive off the
/// main actor, so this sits between the session and `EpisodeDownloader`.
///
/// `@unchecked Sendable`: `routes` and `outcomes` are mutated from both the
/// serial delegate queue and the main actor (at registration time), and both
/// are guarded by `lock`.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Route {
        let episodeID: String
        let destination: URL
    }

    /// Set once at construction; the downloader is `@MainActor`, hence Sendable.
    weak var owner: EpisodeDownloader?

    private let lock = NSLock()
    private var routes: [Int: Route] = [:]
    private var outcomes: [Int: (fileURL: URL?, failure: String?)] = [:]

    func register(task: Int, episode: String, destination: URL) {
        lock.lock()
        defer { lock.unlock() }
        routes[task] = Route(episodeID: episode, destination: destination)
    }

    private func route(_ task: Int) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        return routes[task]
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let route = route(downloadTask.taskIdentifier) else { return }

        // A chunked response reports -1 for the expected total. Publishing a
        // negative fraction would drive the progress bar backwards, so those
        // ticks are dropped and the bar stays indeterminate.
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))

        let owner = self.owner
        let episodeID = route.episodeID
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in owner?.report(fraction, for: episodeID, task: taskID) }
    }

    /// The temp file is deleted the moment this returns, so the move happens
    /// here synchronously rather than being handed to the main actor first.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let route = route(downloadTask.taskIdentifier) else { return }

        // A 404 or a paywall page still "downloads" successfully — the body is
        // just HTML. Without this check we would happily save it as an .mp3.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            record(downloadTask.taskIdentifier, fileURL: nil, failure: "HTTP \(http.statusCode)")
            return
        }

        do {
            try FileManager.default.removeItem(at: route.destination)
        } catch CocoaError.fileNoSuchFile {
            // Nothing to replace — the normal case.
        } catch {
            record(downloadTask.taskIdentifier, fileURL: nil, failure: error.localizedDescription)
            return
        }

        do {
            try FileManager.default.moveItem(at: location, to: route.destination)
            record(downloadTask.taskIdentifier, fileURL: route.destination, failure: nil)
        } catch {
            record(downloadTask.taskIdentifier, fileURL: nil, failure: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let route = routes.removeValue(forKey: task.taskIdentifier)
        let outcome = outcomes.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let route else { return }

        let cancelled = (error as? URLError)?.code == .cancelled
        let failure = error.map { $0.localizedDescription } ?? outcome?.failure
        let fileURL = error == nil ? outcome?.fileURL : nil

        let owner = self.owner
        let episodeID = route.episodeID
        let taskID = task.taskIdentifier
        Task { @MainActor in
            owner?.finish(
                episodeID: episodeID,
                task: taskID,
                fileURL: fileURL,
                failure: failure ?? "the download did not complete",
                cancelled: cancelled
            )
        }
    }

    private func record(_ task: Int, fileURL: URL?, failure: String?) {
        lock.lock()
        defer { lock.unlock() }
        outcomes[task] = (fileURL, failure)
    }
}
