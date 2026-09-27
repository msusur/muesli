import AVFAudio
import CoreMedia
import Foundation
import MuesliAudio
import MuesliCore
import os
import Speech

/// Turns one stream of audio (mic *or* system) into timestamped segments using
/// Apple's on-device `SpeechAnalyzer`. Run one per stream and merge the output
/// into a `Transcript`.
@available(macOS 26.0, *)
public struct StreamTranscriber: Sendable {
    public enum TranscribeError: Error, LocalizedError {
        case unavailable
        case unsupportedLocale(String)
        case noAudioFormat
        case conversion(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: "On-device speech transcription isn't available on this Mac."
            case .unsupportedLocale(let id): "Speech recognition doesn't support the locale “\(id)”."
            case .noAudioFormat: "The speech model didn't report a usable audio format."
            case .conversion(let why): "Audio format conversion failed: \(why)"
            }
        }
    }

    public let speaker: Speaker
    public let locale: Locale
    /// Host time (see `HostClock`) that all segment timestamps are relative to,
    /// so mic and system segments line up. `nil` → this stream's own start.
    public let sessionStart: UInt64?

    public init(speaker: Speaker, locale: Locale, sessionStart: UInt64? = nil) {
        self.speaker = speaker
        self.locale = locale
        self.sessionStart = sessionStart
    }

    // MARK: - Model management

    /// Maps the requested locale to one the recognizer supports and makes sure
    /// its on-device model is installed (downloading it if needed).
    public static func prepare(locale: Locale, onDownload: @Sendable (Progress) -> Void = { _ in }) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw TranscribeError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscribeError.unsupportedLocale(locale.identifier)
        }
        let probe = makeTranscriber(locale: supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            onDownload(request.progress)
            try await request.downloadAndInstall()
        }
        return supported
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    // MARK: - Transcription

    /// Consumes `chunks` until the stream ends, yielding finalized segments as
    /// the recognizer produces them. The returned stream finishes after the
    /// last segment has been flushed.
    public func transcribe(_ chunks: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(chunks, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ chunks: AsyncStream<AudioChunk>, into out: AsyncThrowingStream<TranscriptSegment, Error>.Continuation) async throws {
        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscribeError.noAudioFormat
        }

        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        try await analyzer.start(inputSequence: inputs)

        // Analyzer time starts at 0 with this stream's first buffer; this is
        // how far after the *session* start that was.
        let offset = OSAllocatedUnfairLock(initialState: TimeInterval(0))
        let speaker = self.speaker
        let sessionStart = self.sessionStart

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let base = offset.withLock { $0 }
                    let start = base + result.range.start.seconds
                    let end = base + result.range.end.seconds
                    out.yield(TranscriptSegment(
                        speaker: speaker,
                        start: start,
                        end: max(end, start),
                        text: text,
                        confidence: Self.meanConfidence(result.text)
                    ))
                }
            }

            group.addTask {
                var converter: PCMConverter?
                var sawFirst = false
                for await chunk in chunks {
                    if !sawFirst {
                        sawFirst = true
                        if let sessionStart, chunk.hostTime != 0 {
                            offset.withLock { $0 = HostClock.seconds(from: sessionStart, to: chunk.hostTime) }
                        }
                    }
                    if converter == nil || converter?.inputFormat != chunk.buffer.format {
                        do {
                            converter = try PCMConverter(from: chunk.buffer.format, to: analyzerFormat)
                        } catch {
                            throw TranscribeError.conversion(error.localizedDescription)
                        }
                    }
                    do {
                        if let converted = try converter?.convert(chunk.buffer) {
                            inputContinuation.yield(AnalyzerInput(buffer: converted))
                        }
                    } catch {
                        throw TranscribeError.conversion(error.localizedDescription)
                    }
                }
                inputContinuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }

            try await group.waitForAll()
        }
    }

    private static func meanConfidence(_ text: AttributedString) -> Double? {
        var total = 0.0, count = 0
        for run in text.runs {
            if let c = run.transcriptionConfidence {
                total += c
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }
}
