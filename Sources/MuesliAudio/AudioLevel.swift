import AVFAudio
import Foundation

/// Peak levels of captured audio, for meters and for noticing a stream that is
/// silent when it shouldn't be.
public enum AudioLevel {
    /// The floor reported for silence, in dBFS.
    public static let silence: Float = -100

    /// The loudest sample in `buffer`, in dBFS (0 is full scale).
    public static func peakDecibels(_ buffer: AVAudioPCMBuffer) -> Float {
        let peak = peakAmplitude(buffer)
        return peak > 0 ? max(silence, 20 * log10(peak)) : silence
    }

    /// The loudest sample as a linear amplitude in 0...1. Exactly 0 means every
    /// sample was zero: digital silence, which is what a process tap delivers when
    /// the System Audio Recording permission hasn't been granted.
    public static func peakAmplitude(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let format = buffer.format
        var peak: Float = 0
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { continue }
            switch format.commonFormat {
            case .pcmFormatFloat32:
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(audio.mDataByteSize) / 4)
                for s in samples { peak = max(peak, abs(s)) }
            case .pcmFormatInt16:
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: Int(audio.mDataByteSize) / 2)
                for s in samples { peak = max(peak, Float(abs(Int32(s))) / 32768) }
            case .pcmFormatInt32:
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: Int(audio.mDataByteSize) / 4)
                for s in samples { peak = max(peak, Float(abs(Int64(s))) / 2_147_483_648) }
            case .pcmFormatFloat64:
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Double.self), count: Int(audio.mDataByteSize) / 8)
                for s in samples { peak = max(peak, Float(abs(s))) }
            default:
                return 0
            }
        }
        return min(peak, 1)
    }

    /// A pass-through that reports each chunk's peak amplitude (0...1) before
    /// forwarding it. Ends when the source ends.
    public static func metering(
        _ source: AsyncStream<AudioChunk>, report: @escaping @Sendable (Float) -> Void
    ) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        Task.detached {
            for await chunk in source {
                report(peakAmplitude(chunk.buffer))
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        return stream
    }
}
