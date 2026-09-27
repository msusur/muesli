import AVFAudio
import Foundation

/// Measures how loud each short frame of an audio file is. It streams through
/// the file, so an hour of audio costs a few hundred kilobytes, not the audio.
public enum FrameEnergy {
    public struct Measurement: Sendable, Equatable {
        /// Loudness of each frame in dBFS, floored at -100.
        public var decibels: [Float]
        public var frameSeconds: TimeInterval
    }

    public static func measure(_ url: URL, frameSeconds: TimeInterval = 0.03) throws -> Measurement {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameLength = max(1, Int(format.sampleRate * frameSeconds))
        let block = AVAudioFrameCount(frameLength * 512)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
            throw PCMConverter.ConversionError.unsupported("(couldn't allocate a buffer)")
        }

        var decibels: [Float] = []
        decibels.reserveCapacity(Int(file.length) / frameLength + 1)
        var carry: [Float] = []

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            // Mix down to mono, then cut into whole frames (the tail carries over).
            var mono = carry
            mono.reserveCapacity(carry.count + count)
            let channelCount = Int(format.channelCount)
            for i in 0 ..< count {
                var sum: Float = 0
                for c in 0 ..< channelCount { sum += channels[c][i] }
                mono.append(sum / Float(channelCount))
            }
            var start = 0
            while start + frameLength <= mono.count {
                var energy: Float = 0
                for i in start ..< start + frameLength { energy += mono[i] * mono[i] }
                let rms = (energy / Float(frameLength)).squareRoot()
                decibels.append(max(-100, 20 * log10(max(rms, 1e-9))))
                start += frameLength
            }
            carry = Array(mono[start...])
        }
        return Measurement(decibels: decibels, frameSeconds: Double(frameLength) / format.sampleRate)
    }
}
