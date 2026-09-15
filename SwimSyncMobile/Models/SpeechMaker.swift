import Foundation
import AVFoundation

/// Drives `SpeechSynthesis` for the UI: one job at a time, with progress.
@MainActor
final class SpeechMaker: ObservableObject {
    @Published private(set) var progress: Double?
    @Published var problem: String?

    private var task: Task<URL?, Never>?

    var isRunning: Bool { task != nil }

    /// `Documents/Speech`, visible in the Files app alongside Episodes and Music.
    var folder: URL {
        let folder = URL.documentsDirectory.appendingPathComponent("Speech", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func destination(forTitle title: String) -> URL {
        var stem = FileNaming.sanitize(title.trimmingCharacters(in: .whitespacesAndNewlines))
        if stem.isEmpty { stem = "Spoken text" }
        if stem.count > 120 { stem = String(stem.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return folder.appendingPathComponent("\(stem).mp3")
    }

    /// Renders and returns the MP3, or nil after a failure or cancel (the
    /// failure is in `problem`).
    func render(text: String, title: String, voice: AVSpeechSynthesisVoice?, rate: Float) async -> URL? {
        guard task == nil else { return nil }
        progress = 0

        let request = SpeechSynthesis.Request(
            text: text,
            voice: voice,
            rate: rate,
            tags: ID3Writer.Tags(title: title, artist: voice?.name ?? "Spoken text", album: "Spoken text"),
            destination: destination(forTitle: title)
        )

        let job = Task<URL?, Never> { [weak self] in
            let synthesis = SpeechSynthesis()
            do {
                try await synthesis.render(request) { fraction in
                    Task { @MainActor [weak self] in
                        if self?.task != nil { self?.progress = fraction }
                    }
                }
                return request.destination
            } catch {
                if case SpeechSynthesis.SpeechError.cancelled = error { return nil }
                if error is CancellationError { return nil }
                await MainActor.run { self?.problem = "Couldn't create the recording — \(error.localizedDescription)." }
                return nil
            }
        }
        task = job
        let result = await job.value
        task = nil
        progress = nil
        return result
    }

    func cancel() {
        task?.cancel()
    }
}
