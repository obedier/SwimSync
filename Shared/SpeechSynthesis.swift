import Foundation
import AVFoundation

/// Reads a text aloud into an MP3 with the system voices.
///
/// `AVSpeechSynthesizer.write` hands back PCM buffers instead of playing them;
/// each is pushed straight through LAME so a long document never sits in
/// memory as raw audio. The text is spoken a paragraph at a time, which is
/// what makes progress reportable — a single utterance gives no ticks until
/// it is finished.
final class SpeechSynthesis {
    struct Request {
        let text: String
        let voice: AVSpeechSynthesisVoice?
        /// `AVSpeechUtteranceDefaultSpeechRate` is 0.5; 0.55 reads as
        /// "audiobook" rather than "screen reader".
        let rate: Float
        let tags: ID3Writer.Tags
        let destination: URL
    }

    enum SpeechError: LocalizedError {
        case emptyText
        case noAudio
        case cancelled

        var errorDescription: String? {
            switch self {
            case .emptyText: return "there is nothing to read — the file is empty"
            case .noAudio: return "the voice produced no audio"
            case .cancelled: return "cancelled"
            }
        }
    }

    /// Voices for the user's language, best quality first. Falls back to
    /// every installed voice when none match, rather than an empty picker.
    static func voices(for language: String = Locale.preferredLanguages.first ?? "en") -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2)).lowercased()
        let all = AVSpeechSynthesisVoice.speechVoices()
        let matching = all.filter { $0.language.lowercased().hasPrefix(prefix) }
        let pool = matching.isEmpty ? all : matching
        return pool.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return a.name < b.name
        }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    /// Splits on blank lines, then on sentences when a paragraph runs long,
    /// so every chunk is a natural pause and the progress bar moves.
    static func chunks(of text: String, limit: Int = 1200) -> [String] {
        let paragraphs = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return paragraphs.flatMap { paragraph -> [String] in
            guard paragraph.count > limit else { return [paragraph] }
            var pieces: [String] = []
            var current = ""
            paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
                let s = sentence ?? ""
                if current.count + s.count > limit, !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                current += s
            }
            if !current.isEmpty { pieces.append(current) }
            return pieces
        }
    }

    private let synthesizer = AVSpeechSynthesizer()

    /// Runs to completion or throws; `progress` is 0...1 by characters spoken.
    func render(_ request: Request, progress: @escaping @Sendable (Double) -> Void) async throws {
        let pieces = Self.chunks(of: request.text)
        guard !pieces.isEmpty else { throw SpeechError.emptyText }
        let total = Double(pieces.reduce(0) { $0 + $1.count })

        try FileManager.default.createDirectory(
            at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let tmp = request.destination.deletingLastPathComponent()
            .appendingPathComponent(".\(request.destination.lastPathComponent).part")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw AudioTranscoder.TranscodeError.cannotRead("couldn't create \(tmp.lastPathComponent)")
        }
        let file = try FileHandle(forWritingTo: tmp)
        let sink = EncodingSink(file: file, tags: request.tags)

        do {
            var spoken = 0.0
            for piece in pieces {
                try Task.checkCancellation()
                let utterance = AVSpeechUtterance(string: piece)
                utterance.voice = request.voice
                utterance.rate = request.rate
                // A beat between paragraphs, like a narrator would leave.
                utterance.postUtteranceDelay = 0.35
                try await speak(utterance, into: sink)
                spoken += Double(piece.count)
                progress(min(1, spoken / total))
            }
            try sink.finish()
            try file.close()
            guard sink.wroteAudio else { throw SpeechError.noAudio }
            try? FileManager.default.removeItem(at: request.destination)
            try FileManager.default.moveItem(at: tmp, to: request.destination)
        } catch {
            synthesizer.stopSpeaking(at: .immediate)
            try? file.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error is CancellationError ? SpeechError.cancelled : error
        }
    }

    /// One utterance, buffer by buffer. The synthesizer marks the end with a
    /// zero-length buffer; that is the only completion signal `write` gives.
    private func speak(_ utterance: AVSpeechUtterance, into sink: EncodingSink) async throws {
        let box = ContinuationBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.set(continuation)
                synthesizer.write(utterance) { buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 {
                        box.resume(with: sink.pendingError.map { .failure($0) } ?? .success(()))
                        return
                    }
                    sink.append(pcm)
                }
            }
        } onCancel: {
            // `write` has no cancellation of its own and the terminating
            // buffer may never come once it is stopped, so the continuation
            // is resumed from here rather than waited for.
            synthesizer.stopSpeaking(at: .immediate)
            box.resume(with: .failure(CancellationError()))
        }
    }
}

/// Serialises PCM buffers from the synthesizer into one LAME stream.
///
/// The write callback runs on a private queue but never concurrently for a
/// single utterance, and utterances are awaited one at a time above, so the
/// encoder sees a strictly ordered stream without needing a lock.
private final class EncodingSink: @unchecked Sendable {
    private let file: FileHandle
    private let tags: ID3Writer.Tags
    private var encoder: MP3Encoder?
    private(set) var pendingError: Error?
    private(set) var wroteAudio = false

    init(file: FileHandle, tags: ID3Writer.Tags) {
        self.file = file
        self.tags = tags
    }

    func append(_ pcm: AVAudioPCMBuffer) {
        guard pendingError == nil else { return }
        do {
            if encoder == nil { try start(with: pcm.format) }
            guard let encoder else { return }
            let frames = Int(pcm.frameLength)
            let channels = Int(pcm.format.channelCount)
            let planar = !pcm.format.isInterleaved && channels > 1
            let encoded: Data
            // Voices differ: some produce Int16, the neural ones Float32.
            if let floats = pcm.floatChannelData {
                encoded = planar
                    ? try interleaved(floats, channels: channels, frames: frames).withUnsafeBufferPointer {
                        try encoder.encode(float: $0.baseAddress!, frames: frames)
                    }
                    : try encoder.encode(float: floats[0], frames: frames)
            } else if let ints = pcm.int16ChannelData {
                encoded = planar
                    ? try interleaved(ints, channels: channels, frames: frames).withUnsafeBufferPointer {
                        try encoder.encode(int16: $0.baseAddress!, frames: frames)
                    }
                    : try encoder.encode(int16: ints[0], frames: frames)
            } else {
                throw AudioTranscoder.TranscodeError.cannotRead("unsupported speech sample format")
            }
            if !encoded.isEmpty {
                try file.write(contentsOf: encoded)
                wroteAudio = true
            }
        } catch {
            pendingError = error
        }
    }

    func finish() throws {
        if let pendingError { throw pendingError }
        guard let encoder else { return }
        try file.write(contentsOf: try encoder.finish())
    }

    private func start(with format: AVAudioFormat) throws {
        let channels = Int(format.channelCount)
        var rate = Int(format.sampleRate.rounded())
        // 22050 is what most voices use; anything odd is nudged to the
        // nearest rate LAME accepts, which it resamples internally.
        if !MP3Encoder.supportedSampleRates.contains(rate) {
            rate = MP3Encoder.supportedSampleRates.min { abs($0 - rate) < abs($1 - rate) } ?? 22050
        }
        encoder = try MP3Encoder(.speech(sampleRate: rate, channels: min(channels, 2)))
        try file.write(contentsOf: ID3Writer.tag(tags))
    }

    private func interleaved<T>(_ planes: UnsafePointer<UnsafeMutablePointer<T>>, channels: Int, frames: Int) -> [T] {
        var out: [T] = []
        out.reserveCapacity(frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels { out.append(planes[channel][frame]) }
        }
        return out
    }
}

/// A continuation that can only be resumed once, however many times the
/// synthesizer decides to signal completion — or cancellation gets there first.
private final class ContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var early: Result<Void, Error>?
    private let lock = NSLock()

    /// Installs the continuation; if a result already arrived, delivers it.
    func set(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        guard early == nil else { lock.unlock(); return }
        early = result
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
