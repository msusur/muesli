import AVFAudio
import Foundation

/// Writes a stream of captured audio to a 16 kHz mono 16-bit WAV file: the
/// format speech models want, at about 115 MB per hour.
///
/// Recording audio is opt-in and temporary by design: muesli only keeps it long
/// enough to run a second speech engine over it, and deletes it afterwards
/// unless asked not to.
public final class StreamRecorder: @unchecked Sendable {
    public static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    public let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: PCMConverter?
    private var _firstHostTime: UInt64?
    private var _framesWritten: AVAudioFramePosition = 0

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = try AVAudioFile(
            forWriting: url,
            settings: Self.format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    /// Host time of the first chunk written, for aligning this stream on the session clock.
    public var firstHostTime: UInt64? { lock.withLock { _firstHostTime } }

    public var duration: TimeInterval { lock.withLock { Double(_framesWritten) / Self.format.sampleRate } }

    public func write(_ chunk: AudioChunk) throws {
        try lock.withLock {
            guard let file else { return }
            if _firstHostTime == nil { _firstHostTime = chunk.hostTime }
            if converter == nil || converter?.inputFormat != chunk.buffer.format {
                converter = try PCMConverter(from: chunk.buffer.format, to: Self.format)
            }
            guard let converted = try converter?.convert(chunk.buffer) else { return }
            try file.write(from: converted)
            _framesWritten += AVAudioFramePosition(converted.frameLength)
        }
    }

    /// Writes what the converter was still holding, and closes the file. Safe to
    /// call more than once.
    public func finish() {
        lock.withLock {
            if let file, let tail = try? converter?.flush() {
                try? file.write(from: tail)
                _framesWritten += AVAudioFramePosition(tail.frameLength)
            }
            file = nil
        }
    }
}

public enum AudioTee {
    /// A pass-through: every chunk is written to `recorder` and then forwarded, so
    /// the caller can transcribe live while the audio is saved. The recorder is
    /// closed when the source stream ends.
    public static func recording(
        _ source: AsyncStream<AudioChunk>, to recorder: StreamRecorder,
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        Task.detached {
            for await chunk in source {
                do { try recorder.write(chunk) } catch { onError(error) }
                continuation.yield(chunk)
            }
            recorder.finish()
            continuation.finish()
        }
        return stream
    }
}
