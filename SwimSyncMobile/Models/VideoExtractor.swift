import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Pulls the soundtrack out of a video into an MP3 the player can use.
///
/// YouTube's own app keeps its downloads encrypted inside its container, so
/// what arrives here is a video the user saved with something else — a
/// downloader app, Safari, or the Photos library. Whatever it is, if
/// AVFoundation can open it the audio track comes out through
/// `AudioTranscoder`; the video track is never read.
@MainActor
final class VideoExtractor: ObservableObject {
    struct Job: Identifiable {
        let id: String
        let name: String
        var progress: Double
    }

    @Published private(set) var jobs: [Job] = []
    @Published var problem: String?

    /// Called on the main actor as each MP3 lands.
    var onExtracted: ((URL) -> Void)?

    private var tasks: [String: Task<Void, Never>] = [:]
    /// Picker URLs stay valid only while their scope is held.
    private var scopes: [String: URL] = [:]

    static let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// `Documents/Videos`, where the extracted MP3s live.
    var folder: URL {
        let folder = URL.documentsDirectory.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies of videos picked from Photos, which hand over a temporary file
    /// that is gone by the time a long extraction would finish.
    var importFolder: URL {
        let folder = folder.appendingPathComponent("Imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func destination(for source: URL) -> URL {
        var stem = FileNaming.sanitize(source.deletingPathExtension().lastPathComponent)
        if stem.isEmpty { stem = "Video" }
        if stem.count > 120 { stem = String(stem.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return folder.appendingPathComponent("\(stem).mp3")
    }

    func extract(_ source: URL) {
        let id = source.path
        guard tasks[id] == nil else { return }

        let destination = destination(for: source)
        if FileManager.default.fileExists(atPath: destination.path) {
            onExtracted?(destination)
            return
        }

        if source.startAccessingSecurityScopedResource() { scopes[id] = source }
        jobs.append(Job(id: id, name: source.lastPathComponent, progress: 0))

        let tags = ID3Writer.Tags(
            title: source.deletingPathExtension().lastPathComponent,
            artist: nil,
            album: "Videos"
        )
        tasks[id] = Task { [weak self] in
            let outcome: Result<Void, Error>
            do {
                try await AudioTranscoder.exportMP3(
                    from: AVURLAsset(url: source), to: destination, tags: tags
                ) { fraction in
                    Task { @MainActor [weak self] in self?.report(fraction, for: id) }
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            self?.finish(id, name: source.lastPathComponent, at: destination, outcome: outcome)
        }
    }

    func cancel(_ job: Job) {
        tasks.removeValue(forKey: job.id)?.cancel()
        jobs.removeAll { $0.id == job.id }
        release(job.id)
    }

    private func report(_ fraction: Double, for id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = fraction
    }

    private func finish(_ id: String, name: String, at url: URL, outcome: Result<Void, Error>) {
        guard tasks.removeValue(forKey: id) != nil else { return }
        jobs.removeAll { $0.id == id }
        release(id)
        switch outcome {
        case .success:
            onExtracted?(url)
        case .failure(let error):
            if case AudioTranscoder.TranscodeError.cancelled = error { return }
            problem = Self.explain(error, name: name)
        }
    }

    /// AVFoundation's own message for an unreadable container is a bare
    /// "cannot open"; say which formats do work instead.
    private static func explain(_ error: Error, name: String) -> String {
        if case AudioTranscoder.TranscodeError.noAudioTrack = error {
            return "“\(name)” has no audio track."
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["webm", "mkv", "flv", "ogv"].contains(ext) {
            return "“\(name)” is a \(ext.uppercased()) file, which iOS can't open. Download it as MP4 instead."
        }
        return "Couldn't get the audio from “\(name)” — \(error.localizedDescription)."
    }

    private func release(_ id: String) {
        scopes.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }
}
