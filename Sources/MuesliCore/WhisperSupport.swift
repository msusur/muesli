import Foundation

// MARK: - Speech gate

/// A stretch of a recording that contains speech.
public struct SpeechRegion: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var duration: TimeInterval { end - start }

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// Decides which parts of a recording are worth sending to Whisper.
///
/// Whisper invents text when it's given silence or steady noise: in testing it
/// wrote "you you" for a minute of digital silence and "Thank you. Thank you."
/// for quiet noise. muesli records the microphone and the system audio as two
/// separate streams, and each is silent whenever the other side is talking, so
/// gating is essential rather than an optimization.
///
/// This is a simple energy gate, not a neural VAD. It adapts to each stream's
/// own noise floor, which is enough to keep silence and steady background noise
/// out; it won't separate speech from speech-like noise such as music.
public enum SpeechGate {
    public struct Configuration: Sendable, Equatable {
        /// How far above the stream's noise floor a frame must be to count as speech.
        public var marginDecibels: Float = 9
        /// Nothing quieter than this is ever speech, however low the noise floor.
        public var minimumSpeechDecibels: Float = -42
        /// Below this spread between the quietest and loudest frames, level can't
        /// tell speech from noise (the stream is all one or the other), so only the
        /// absolute threshold applies. Losing speech is worse than keeping noise.
        public var minimumDynamicRangeDecibels: Float = 10
        /// Pauses shorter than this don't split a region.
        public var mergeGapSeconds: TimeInterval = 0.8
        /// Bursts shorter than this are clicks and coughs, not speech.
        public var minimumRegionSeconds: TimeInterval = 0.3
        /// Context kept on each side so word onsets aren't clipped.
        public var paddingSeconds: TimeInterval = 0.25

        public init() {}
    }

    /// - Parameter frameDecibels: Loudness of consecutive equal-length frames, in dBFS.
    public static func regions(
        frameDecibels: [Float], frameSeconds: TimeInterval, configuration: Configuration = Configuration()
    ) -> [SpeechRegion] {
        guard !frameDecibels.isEmpty, frameSeconds > 0 else { return [] }

        // The quietest tenth of frames approximates the noise floor: pauses and room
        // tone. But a stream that is nearly all speech (someone monologuing) has no
        // quiet frames, and treating its speech level as "noise" would discard the
        // whole stream. So with too little dynamic range, fall back to the absolute level.
        let sorted = frameDecibels.sorted()
        func percentile(_ p: Double) -> Float { sorted[Int(Double(sorted.count - 1) * p)] }
        let quiet = percentile(0.10)
        let loud = percentile(0.95)
        let threshold: Float = loud - quiet < configuration.minimumDynamicRangeDecibels
            ? configuration.minimumSpeechDecibels
            : max(quiet + configuration.marginDecibels, configuration.minimumSpeechDecibels)

        var raw: [SpeechRegion] = []
        var runStart: Int?
        for (index, level) in frameDecibels.enumerated() {
            if level > threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                raw.append(SpeechRegion(start: Double(start) * frameSeconds, end: Double(index) * frameSeconds))
                runStart = nil
            }
        }
        if let start = runStart {
            raw.append(SpeechRegion(start: Double(start) * frameSeconds, end: Double(frameDecibels.count) * frameSeconds))
        }

        // Join regions separated by a short pause, drop blips, pad, and re-join any overlap.
        let total = Double(frameDecibels.count) * frameSeconds
        var merged: [SpeechRegion] = []
        for region in raw {
            if var last = merged.last, region.start - last.end <= configuration.mergeGapSeconds {
                last.end = region.end
                merged[merged.count - 1] = last
            } else {
                merged.append(region)
            }
        }
        var padded: [SpeechRegion] = []
        for region in merged where region.duration >= configuration.minimumRegionSeconds {
            let p = SpeechRegion(
                start: max(0, region.start - configuration.paddingSeconds),
                end: min(total, region.end + configuration.paddingSeconds))
            if var last = padded.last, p.start <= last.end {
                last.end = max(last.end, p.end)
                padded[padded.count - 1] = last
            } else {
                padded.append(p)
            }
        }
        return padded
    }
}

// MARK: - Segment quality filter

/// Whisper's own confidence signals for one segment.
public struct WhisperQuality: Sendable, Equatable {
    public var noSpeechProbability: Double?
    public var averageLogProbability: Double?
    /// How compressible the text is; high means a repetition loop.
    public var compressionRatio: Double?

    public init(noSpeechProbability: Double? = nil, averageLogProbability: Double? = nil, compressionRatio: Double? = nil) {
        self.noSpeechProbability = noSpeechProbability
        self.averageLogProbability = averageLogProbability
        self.compressionRatio = compressionRatio
    }
}

/// Drops segments Whisper itself signals are not real speech. The silence gate
/// catches most of these before they exist; this is the second line of defence.
public enum WhisperFilter {
    /// Stock phrases Whisper emits over non-speech (from its training data).
    private static let boilerplate: Set<String> = [
        "you", "thank you", "thanks", "thanks for watching", "thank you for watching",
        "bye", "bye bye", "subtitles by the amara.org community",
    ]

    public static func keeps(text: String, quality: WhisperQuality) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Whisper's standard "this was silence" test.
        if let noSpeech = quality.noSpeechProbability, let logProb = quality.averageLogProbability,
           noSpeech > 0.6, logProb < -1.0 { return false }
        // A repetition loop.
        if let ratio = quality.compressionRatio, ratio > 2.4 { return false }
        // A stock phrase, when Whisper is at all unsure there was speech. A real
        // "thank you" from a person has a low no-speech probability and survives.
        let normalized = trimmed.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if boilerplate.contains(normalized), (quality.noSpeechProbability ?? 0) >= 0.4 { return false }
        return true
    }
}

// MARK: - Recorded audio manifest

/// Where a session's recorded audio lives (`audio/audio.json`), so it can be
/// transcribed again later with a different engine.
public struct SessionAudio: Codable, Sendable, Equatable {
    public struct Stream: Codable, Sendable, Equatable {
        public var speaker: Speaker
        /// Relative to the `audio` folder.
        public var file: String
        /// Seconds between the session start and this stream's first sample.
        public var startOffset: TimeInterval

        public init(speaker: Speaker, file: String, startOffset: TimeInterval) {
            self.speaker = speaker
            self.file = file
            self.startOffset = startOffset
        }
    }

    public var streams: [Stream]

    public init(streams: [Stream]) {
        self.streams = streams
    }

    public static let folderName = "audio"
    public static let manifestName = "audio.json"

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func load(jsonData data: Data) throws -> SessionAudio {
        try JSONDecoder().decode(SessionAudio.self, from: data)
    }
}
