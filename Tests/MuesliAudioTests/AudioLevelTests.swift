import AVFAudio
import Foundation
import Testing
@testable import MuesliAudio

private func buffer(_ format: AVAudioCommonFormat, interleaved: Bool = false, channels: AVAudioChannelCount = 1, fill: (Int) -> Double) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: format, sampleRate: 48_000, channels: channels, interleaved: interleaved)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        switch format.commonFormat {
        case .pcmFormatFloat32:
            let p = audio.mData!.assumingMemoryBound(to: Float.self)
            for i in 0 ..< Int(audio.mDataByteSize) / 4 { p[i] = Float(fill(i)) }
        case .pcmFormatInt16:
            let p = audio.mData!.assumingMemoryBound(to: Int16.self)
            for i in 0 ..< Int(audio.mDataByteSize) / 2 { p[i] = Int16(fill(i) * 32767) }
        default: break
        }
    }
    return buffer
}

@Suite("AudioLevel")
struct AudioLevelTests {
    @Test("all-zero samples are digital silence, which is how a tap without permission looks")
    func zeroIsSilence() {
        let b = buffer(.pcmFormatFloat32) { _ in 0 }
        #expect(AudioLevel.peakAmplitude(b) == 0)
        #expect(AudioLevel.peakDecibels(b) == AudioLevel.silence)
    }

    @Test("peak is the loudest sample, of either sign, in any channel")
    func peakOfStereo() {
        let b = buffer(.pcmFormatFloat32, channels: 2) { i in i == 100 ? -0.5 : 0.1 }
        #expect(abs(AudioLevel.peakAmplitude(b) - 0.5) < 0.0001)
        #expect(abs(AudioLevel.peakDecibels(b) - (-6.02)) < 0.05)
    }

    @Test("16-bit interleaved audio is read too")
    func int16() {
        let b = buffer(.pcmFormatInt16, interleaved: true, channels: 2) { i in i == 7 ? 0.25 : 0 }
        #expect(abs(AudioLevel.peakAmplitude(b) - 0.25) < 0.001)
    }

    @Test("a very quiet signal is still not silence")
    func quietIsNotSilence() {
        let b = buffer(.pcmFormatFloat32) { i in i == 0 ? 1e-7 : 0 }
        #expect(AudioLevel.peakAmplitude(b) > 0)
        #expect(AudioLevel.peakDecibels(b) == AudioLevel.silence) // below the floor, clamped
    }

    @Test("metering forwards every chunk and reports each one's peak")
    func metering() async {
        let (source, input) = AsyncStream.makeStream(of: AudioChunk.self)
        let peaks = Peaks()
        let metered = AudioLevel.metering(source) { peaks.append($0) }
        input.yield(AudioChunk(buffer: buffer(.pcmFormatFloat32) { _ in 0 }))
        input.yield(AudioChunk(buffer: buffer(.pcmFormatFloat32) { _ in 0.5 }))
        input.finish()
        var count = 0
        for await _ in metered { count += 1 }
        #expect(count == 2)
        #expect(peaks.values == [0, 0.5])
    }
}

private final class Peaks: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Float] = []
    func append(_ v: Float) { lock.withLock { _values.append(v) } }
    var values: [Float] { lock.withLock { _values } }
}
