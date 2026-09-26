import AVFAudio

/// Feeds an audio file through the same pipeline as live capture. Used for
/// `muesli transcribe <file>` and for tests.
public enum AudioFileSource {
    public static func chunks(url: URL, framesPerChunk: AVAudioFrameCount = 8192) throws -> AsyncStream<AudioChunk> {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        // Reading is fast and synchronous; do it on a background queue so the
        // caller can start consuming immediately.
        DispatchQueue.global(qos: .userInitiated).async {
            defer { continuation.finish() }
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk) else { return }
                do { try file.read(into: buffer, frameCount: framesPerChunk) } catch { return }
                if buffer.frameLength == 0 { return }
                continuation.yield(AudioChunk(buffer: buffer))
            }
        }
        return stream
    }
}
