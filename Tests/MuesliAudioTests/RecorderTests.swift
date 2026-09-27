import AVFAudio
import Foundation
import Testing
@testable import MuesliAudio

private func sine(rate: Double, channels: AVAudioChannelCount = 1, seconds: Double, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    let frames = AVAudioFrameCount(rate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0 ..< Int(channels) {
        let data = buffer.floatChannelData![c]
        for i in 0 ..< Int(frames) { data[i] = amplitude * Float(sin(2 * Double.pi * 440 * Double(i) / rate)) }
    }
    return buffer
}

private func silence(rate: Double, seconds: Double) -> AVAudioPCMBuffer {
    sine(rate: rate, seconds: seconds, amplitude: 0)
}

private func tempFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "muesli-test-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Suite("StreamRecorder")
struct RecorderTests {
    @Test("writes 16 kHz mono 16-bit WAV whatever the input, and keeps the level")
    func convertsToSpeechFormat() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try StreamRecorder(url: folder.appending(path: "nested/mic.wav"))

        // 2 s of a 440 Hz tone captured as 44.1 kHz stereo, delivered in four chunks
        for i in 0 ..< 4 { try recorder.write(AudioChunk(buffer: sine(rate: 44_100, channels: 2, seconds: 0.5), hostTime: 1_000 + UInt64(i))) }
        recorder.finish()

        #expect(recorder.firstHostTime == 1_000)
        #expect(abs(recorder.duration - 2.0) < 0.05)

        let file = try AVAudioFile(forReading: recorder.url)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(abs(Double(file.length) - 32_000) < 100, "file has \(file.length) frames, expected about 32000")

        // sine of amplitude 0.5 has RMS 0.354, i.e. about -9 dBFS
        let measurement = try FrameEnergy.measure(recorder.url)
        let mean = measurement.decibels.reduce(0, +) / Float(measurement.decibels.count)
        #expect(abs(mean - (-9.0)) < 1.0, "mean level \(mean) dBFS")
    }

    @Test("a switch of input format mid-stream (a device change) is handled")
    func formatChange() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try StreamRecorder(url: folder.appending(path: "s.wav"))
        try recorder.write(AudioChunk(buffer: sine(rate: 48_000, seconds: 1)))
        try recorder.write(AudioChunk(buffer: sine(rate: 16_000, seconds: 1)))
        recorder.finish()
        #expect(abs(recorder.duration - 2.0) < 0.05)
    }

    @Test("writing after finish is ignored, and finishing twice is safe")
    func afterFinish() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try StreamRecorder(url: folder.appending(path: "s.wav"))
        try recorder.write(AudioChunk(buffer: sine(rate: 16_000, seconds: 1)))
        recorder.finish()
        recorder.finish()
        try recorder.write(AudioChunk(buffer: sine(rate: 16_000, seconds: 1)))
        #expect(abs(recorder.duration - 1.0) < 0.05)
    }

    @Test("the tee forwards every chunk and records it")
    func tee() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try StreamRecorder(url: folder.appending(path: "s.wav"))
        let (source, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let forwarded = AudioTee.recording(source, to: recorder)
        for _ in 0 ..< 3 { continuation.yield(AudioChunk(buffer: sine(rate: 48_000, seconds: 0.5))) }
        continuation.finish()

        var count = 0
        for await _ in forwarded { count += 1 }
        #expect(count == 3)
        #expect(abs(recorder.duration - 1.5) < 0.05)
        #expect(try AVAudioFile(forReading: recorder.url).length > 20_000)
    }
}

@Suite("FrameEnergy")
struct FrameEnergyTests {
    @Test("silence reads as -100 dB and tone as its level, in 30 ms frames")
    func levels() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try StreamRecorder(url: folder.appending(path: "s.wav"))
        try recorder.write(AudioChunk(buffer: silence(rate: 16_000, seconds: 3)))
        try recorder.write(AudioChunk(buffer: sine(rate: 16_000, seconds: 3, amplitude: 0.1))) // -23 dBFS
        recorder.finish()

        let m = try FrameEnergy.measure(recorder.url)
        #expect(abs(m.frameSeconds - 0.03) < 0.001)
        #expect(abs(Double(m.decibels.count) * m.frameSeconds - 6.0) < 0.1)
        let quiet = m.decibels[10 ..< 80]
        let loud = m.decibels[120 ..< 190]
        #expect(quiet.allSatisfy { $0 <= -99 })
        #expect(loud.allSatisfy { abs($0 - (-23)) < 1.0 })
    }
}
