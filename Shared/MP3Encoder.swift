import Foundation
import lame

/// Constant-bitrate MP3 encoder over LAME.
///
/// AVFoundation can decode MP3 but will not write it, and the player decodes
/// nothing else, so every file the app *creates* — speech from a text file,
/// an AAC song from the phone's library — ends up here.
///
/// One instance per output file. Not thread-safe; feed it from one thread.
final class MP3Encoder {
    struct Configuration {
        let sampleRate: Int
        let channels: Int
        let bitrateKbps: Int

        /// 64 kbps mono is transparent for synthesised speech and keeps an
        /// hour of narration under 30 MB.
        static func speech(sampleRate: Int, channels: Int) -> Configuration {
            Configuration(sampleRate: sampleRate, channels: channels, bitrateKbps: channels == 1 ? 64 : 96)
        }

        /// 192 kbps for music, matching what most stores and rippers use.
        static func music(sampleRate: Int, channels: Int) -> Configuration {
            Configuration(sampleRate: sampleRate, channels: channels, bitrateKbps: channels == 1 ? 128 : 192)
        }
    }

    enum EncoderError: LocalizedError {
        case initialisation
        case unsupported(sampleRate: Int, channels: Int)
        case encode(Int32)

        var errorDescription: String? {
            switch self {
            case .initialisation: return "the MP3 encoder could not start"
            case .unsupported(let rate, let channels):
                return "audio at \(rate) Hz with \(channels) channel\(channels == 1 ? "" : "s") can't be encoded to MP3"
            case .encode(let code): return "MP3 encoding failed (LAME \(code))"
            }
        }
    }

    static let supportedSampleRates: Set<Int> = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]

    private let flags: lame_t
    let configuration: Configuration
    private var scratch: [UInt8]

    init(_ configuration: Configuration) throws {
        guard Self.supportedSampleRates.contains(configuration.sampleRate),
              (1...2).contains(configuration.channels) else {
            throw EncoderError.unsupported(sampleRate: configuration.sampleRate, channels: configuration.channels)
        }
        guard let flags = lame_init() else { throw EncoderError.initialisation }
        self.flags = flags
        self.configuration = configuration
        scratch = []

        lame_set_in_samplerate(flags, Int32(configuration.sampleRate))
        // Same rate out as in: LAME would otherwise pick a lower rate for a
        // low bitrate, which is fine for music and audibly dull for speech.
        lame_set_out_samplerate(flags, Int32(configuration.sampleRate))
        lame_set_num_channels(flags, Int32(configuration.channels))
        lame_set_mode(flags, configuration.channels == 1 ? MONO : JOINT_STEREO)
        lame_set_brate(flags, Int32(configuration.bitrateKbps))
        lame_set_VBR(flags, vbr_off)
        lame_set_quality(flags, 2)
        // Tags are written by ID3Writer so the passthrough path and this one
        // produce identical headers.
        lame_set_write_id3tag_automatic(flags, 0)
        // No Xing/LAME info frame: some cheap decoders play it as a click.
        lame_set_bWriteVbrTag(flags, 0)

        guard lame_init_params(flags) >= 0 else {
            lame_close(flags)
            throw EncoderError.initialisation
        }
    }

    deinit { lame_close(flags) }

    /// Interleaved 16-bit samples, `frames` per channel.
    func encode(int16 pcm: UnsafePointer<Int16>, frames: Int) throws -> Data {
        try withOutput(frames: frames) { out, size in
            if configuration.channels == 1 {
                return lame_encode_buffer(flags, pcm, pcm, Int32(frames), out, size)
            }
            return lame_encode_buffer_interleaved(flags, UnsafeMutablePointer(mutating: pcm), Int32(frames), out, size)
        }
    }

    /// Interleaved 32-bit float samples in -1...1, `frames` per channel.
    func encode(float pcm: UnsafePointer<Float>, frames: Int) throws -> Data {
        try withOutput(frames: frames) { out, size in
            if configuration.channels == 1 {
                return lame_encode_buffer_ieee_float(flags, pcm, pcm, Int32(frames), out, size)
            }
            return lame_encode_buffer_interleaved_ieee_float(flags, pcm, Int32(frames), out, size)
        }
    }

    /// The last frames LAME was holding back. Call once, then discard.
    func finish() throws -> Data {
        try withOutput(frames: 0) { out, size in lame_encode_flush(flags, out, size) }
    }

    private func withOutput(frames: Int, _ body: (UnsafeMutablePointer<UInt8>, Int32) -> Int32) throws -> Data {
        // LAME's documented worst case.
        let needed = Int(1.25 * Double(frames)) + 7200
        if scratch.count < needed { scratch = [UInt8](repeating: 0, count: needed) }
        let written = scratch.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!, Int32(buffer.count))
        }
        guard written >= 0 else { throw EncoderError.encode(written) }
        return Data(scratch.prefix(Int(written)))
    }
}
