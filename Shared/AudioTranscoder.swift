import Foundation
import AVFoundation

/// Turns any readable asset into an MP3 file the player will decode.
///
/// Two paths, chosen by the source codec. An MP3 source has its frames copied
/// out untouched — byte-exact audio, no generation loss, and fast. Anything
/// else (AAC purchases, ALAC, WAV) is decoded to PCM and handed to LAME.
///
/// Every function here runs off the main actor: `AVAssetReader` blocks while
/// it pulls samples, and on an `ipod-library://` source that means reading
/// through the Music app's storage at whatever pace it allows.
enum AudioTranscoder {
    enum TranscodeError: LocalizedError {
        case noAudioTrack
        case cannotRead(String)
        case unsupportedLayout
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "the file has no audio track"
            case .cannotRead(let why): return "the audio couldn't be read — \(why)"
            case .unsupportedLayout: return "only mono and stereo audio can be converted"
            case .cancelled: return "cancelled"
            }
        }
    }

    enum SourceCodec {
        case mp3
        case other(String)

        var isMP3: Bool { if case .mp3 = self { return true } else { return false } }
    }

    /// Whether a source can be copied frame-for-frame or has to be re-encoded.
    static func sourceCodec(of asset: AVAsset) async throws -> SourceCodec {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscodeError.noAudioTrack
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return .other("unknown")
        }
        if asbd.mFormatID == kAudioFormatMPEGLayer3 { return .mp3 }
        return .other(fourCharCode(asbd.mFormatID))
    }

    /// Produces `destination` as an MP3, by whichever path the source needs.
    /// `progress` is 0...1 and arrives on no particular thread.
    static func exportMP3(
        from asset: AVAsset,
        to destination: URL,
        tags: ID3Writer.Tags,
        musicBitrate: Bool = true,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let codec = try await sourceCodec(of: asset)
        let duration = try await asset.load(.duration).seconds
        let track = try await asset.loadTracks(withMediaType: .audio).first

        guard let track else { throw TranscodeError.noAudioTrack }
        let reader = try AVAssetReader(asset: asset)

        // A partial file from a previous attempt would otherwise be appended to.
        try? FileManager.default.removeItem(at: destination)
        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).part")
        try? FileManager.default.removeItem(at: tmp)

        do {
            if codec.isMP3 {
                try copyFrames(track: track, reader: reader, to: tmp, tags: tags, duration: duration, progress: progress)
            } else {
                try encode(track: track, reader: reader, to: tmp, tags: tags, duration: duration,
                           music: musicBitrate, progress: progress)
            }
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - Passthrough

    /// MP3 is a self-synchronising frame stream: the compressed packets an
    /// asset reader hands back with nil output settings *are* the file, minus
    /// the tag. Concatenating them is the whole conversion.
    private static func copyFrames(
        track: AVAssetTrack, reader: AVAssetReader, to url: URL,
        tags: ID3Writer.Tags, duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw TranscodeError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }

        let file = try openForWriting(url)
        defer { try? file.close() }
        try file.write(contentsOf: ID3Writer.tag(tags))

        try drain(reader: reader, output: output, duration: duration, progress: progress) { sample in
            try file.write(contentsOf: try bytes(of: sample))
        }
    }

    // MARK: - Decode and encode

    private static func encode(
        track: AVAssetTrack, reader: AVAssetReader, to url: URL,
        tags: ID3Writer.Tags, duration: Double, music: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        // Rate and channel count are left to the source; LAME is configured
        // from the first decoded buffer rather than guessed up front.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw TranscodeError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }

        let file = try openForWriting(url)
        defer { try? file.close() }
        try file.write(contentsOf: ID3Writer.tag(tags))

        var encoder: MP3Encoder?

        try drain(reader: reader, output: output, duration: duration, progress: progress) { sample in
            if encoder == nil {
                guard let description = CMSampleBufferGetFormatDescription(sample),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                    throw TranscodeError.cannotRead("no audio format")
                }
                let channels = Int(asbd.mChannelsPerFrame)
                guard (1...2).contains(channels) else { throw TranscodeError.unsupportedLayout }
                let rate = Int(asbd.mSampleRate)
                let config = music
                    ? MP3Encoder.Configuration.music(sampleRate: rate, channels: channels)
                    : MP3Encoder.Configuration.speech(sampleRate: rate, channels: channels)
                encoder = try MP3Encoder(config)
            }
            guard let encoder else { return }

            let data = try bytes(of: sample)
            let frames = data.count / (2 * encoder.configuration.channels)
            guard frames > 0 else { return }
            let encoded = try data.withUnsafeBytes { raw in
                try encoder.encode(int16: raw.bindMemory(to: Int16.self).baseAddress!, frames: frames)
            }
            try file.write(contentsOf: encoded)
        }

        if let encoder { try file.write(contentsOf: try encoder.finish()) }
    }

    // MARK: - Shared plumbing

    /// Pulls every sample buffer through `sink`, reporting progress by
    /// timestamp and honouring task cancellation between buffers.
    private static func drain(
        reader: AVAssetReader, output: AVAssetReaderTrackOutput, duration: Double,
        progress: @escaping @Sendable (Double) -> Void,
        sink: (CMSampleBuffer) throws -> Void
    ) throws {
        var lastReported = 0.0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw TranscodeError.cancelled
            }
            try sink(sample)

            if duration > 0 {
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let fraction = min(1, max(0, t / duration))
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }
        switch reader.status {
        case .completed:
            progress(1)
        case .failed:
            throw TranscodeError.cannotRead(reader.error?.localizedDescription ?? "reader failed")
        case .cancelled:
            throw TranscodeError.cancelled
        default:
            throw TranscodeError.cannotRead("reader stopped early")
        }
    }

    private static func bytes(of sample: CMSampleBuffer) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return Data() }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else {
            throw TranscodeError.cannotRead("sample buffer copy failed (\(status))")
        }
        return data
    }

    private static func openForWriting(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TranscodeError.cannotRead("couldn't create \(url.lastPathComponent)")
        }
        return try FileHandle(forWritingTo: url)
    }

    private static func fourCharCode(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }
}
