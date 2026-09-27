import Foundation
import Testing
@testable import MuesliCore

private let frame = 0.03

/// A run of `seconds` at `level` dBFS.
private func run(_ level: Float, _ seconds: Double) -> [Float] {
    [Float](repeating: level, count: Int((seconds / frame).rounded()))
}

@Suite("Speech gate")
struct SpeechGateTests {
    private func regions(_ frames: [Float]) -> [SpeechRegion] {
        SpeechGate.regions(frameDecibels: frames, frameSeconds: frame)
    }

    @Test("silence and steady quiet noise produce nothing: the case where Whisper invents text")
    func silenceAndNoise() {
        #expect(regions([]).isEmpty)
        #expect(regions(run(-100, 60)).isEmpty)              // digital silence
        #expect(regions(run(-48, 60)).isEmpty)               // quiet room tone
        let flutter = (0 ..< 2000).map { Float(-48 + Float($0 % 5)) }
        #expect(regions(flutter).isEmpty)                    // noise that wobbles a little
    }

    @Test("two utterances in silence become two padded regions")
    func twoBursts() throws {
        let frames = run(-100, 5) + run(-20, 3) + run(-100, 6) + run(-20, 2) + run(-100, 4)
        let r = regions(frames)
        try #require(r.count == 2)
        // 5 s..8 s and 14 s..16 s, each padded by 0.25 s
        #expect(abs(r[0].start - 4.75) < 0.1 && abs(r[0].end - 8.25) < 0.1)
        #expect(abs(r[1].start - 13.75) < 0.1 && abs(r[1].end - 16.25) < 0.1)
    }

    @Test("a short pause inside a sentence doesn't split it, a long one does")
    func merging() {
        let short = run(-100, 2) + run(-20, 2) + run(-100, 0.5) + run(-20, 2) + run(-100, 2)
        #expect(regions(short).count == 1)
        let long = run(-100, 2) + run(-20, 2) + run(-100, 2) + run(-20, 2) + run(-100, 2)
        #expect(regions(long).count == 2)
    }

    @Test("clicks and coughs are dropped")
    func blips() {
        #expect(regions(run(-100, 5) + run(-20, 0.1) + run(-100, 5)).isEmpty)
        #expect(regions(run(-100, 5) + run(-20, 0.6) + run(-100, 5)).count == 1)
    }

    @Test("padding is clamped to the recording")
    func clamped() throws {
        let r = regions(run(-20, 4) + run(-100, 3))
        let only = try #require(r.first)
        #expect(only.start == 0)
        #expect(only.end < 4.5)
    }

    @Test("speech over steady noise is found relative to that noise, not an absolute level")
    func adaptsToNoiseFloor() throws {
        // Constant noise at -30 dB with speech at -15 dB
        let frames = run(-30, 6) + run(-15, 3) + run(-30, 6)
        let r = regions(frames)
        try #require(r.count == 1)
        #expect(abs(r[0].start - 5.75) < 0.1 && abs(r[0].end - 9.25) < 0.1)
    }

    @Test("a stream that is almost all speech is kept, not mistaken for noise")
    func continuous() throws {
        // Someone talking for a minute and a half with only brief dips: there are no
        // quiet frames to serve as a noise floor, and the whole stream must survive.
        let withDips = (0 ..< 3000).map { Float($0 % 40 < 3 ? -40 : -22) }
        let r = regions(withDips)
        try #require(r.count == 1)
        #expect(r[0].start == 0 && abs(r[0].end - 90) < 0.1)

        let flat = run(-22, 60)
        #expect(regions(flat).count == 1)
    }

    @Test("long pauses in an otherwise continuous talker still split regions")
    func pausesSplit() {
        let frames = run(-22, 10) + run(-70, 3) + run(-22, 10) + run(-70, 3) + run(-22, 10)
        #expect(regions(frames).count == 3)
    }
}

@Suite("Whisper segment filter")
struct WhisperFilterTests {
    @Test("keeps ordinary speech")
    func keeps() {
        #expect(WhisperFilter.keeps(text: " Please send the budget. ", quality: .init(noSpeechProbability: 0.02, averageLogProbability: -0.3, compressionRatio: 1.4)))
        #expect(WhisperFilter.keeps(text: "Hello", quality: WhisperQuality()))
    }

    @Test("drops empty text, Whisper's own silence verdict, and repetition loops")
    func drops() {
        #expect(!WhisperFilter.keeps(text: "  ", quality: WhisperQuality()))
        #expect(!WhisperFilter.keeps(text: "hmm", quality: .init(noSpeechProbability: 0.9, averageLogProbability: -1.6)))
        #expect(WhisperFilter.keeps(text: "hmm", quality: .init(noSpeechProbability: 0.9, averageLogProbability: -0.4))) // confident
        #expect(!WhisperFilter.keeps(text: "and and and and and", quality: .init(compressionRatio: 3.1)))
    }

    @Test("stock hallucinations go, but a real 'thank you' stays")
    func boilerplate() {
        #expect(!WhisperFilter.keeps(text: "Thank you.", quality: .init(noSpeechProbability: 0.55, averageLogProbability: -0.5)))
        #expect(!WhisperFilter.keeps(text: "you", quality: .init(noSpeechProbability: 0.45)))
        #expect(WhisperFilter.keeps(text: "Thank you.", quality: .init(noSpeechProbability: 0.05, averageLogProbability: -0.2)))
        #expect(WhisperFilter.keeps(text: "Thank you for the update.", quality: .init(noSpeechProbability: 0.5)))
    }
}

@Suite("Session audio manifest")
struct SessionAudioTests {
    @Test("round-trips")
    func roundTrip() throws {
        let manifest = SessionAudio(streams: [
            .init(speaker: .me, file: "mic.wav", startOffset: 0.02),
            .init(speaker: .them, file: "system.wav", startOffset: 4.5),
        ])
        #expect(try SessionAudio.load(jsonData: manifest.jsonData()) == manifest)
    }
}
