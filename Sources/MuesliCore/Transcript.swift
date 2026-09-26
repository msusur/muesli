import Foundation

/// Who said it. Muesli labels speakers by *channel*, not by voice: the
/// microphone is you, system audio is everyone else on the call.
public enum Speaker: String, Codable, Sendable, Hashable {
    case me
    case them

    public var label: String {
        switch self {
        case .me: "Me"
        case .them: "Them"
        }
    }
}

public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var speaker: Speaker
    /// Seconds since the session started.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// 0...1 when the recognizer reports it.
    public var confidence: Double?

    public init(
        id: UUID = UUID(),
        speaker: Speaker,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Double? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var locale: String
    /// Where the meeting happened, so "by Monday" resolves in the right zone even
    /// if the notes are generated later or elsewhere. Absent in older files.
    public var timeZoneIdentifier: String?
    public private(set) var segments: [TranscriptSegment]

    public init(
        startedAt: Date = Date(), locale: String, timeZoneIdentifier: String? = TimeZone.current.identifier,
        segments: [TranscriptSegment] = []
    ) {
        self.startedAt = startedAt
        self.locale = locale
        self.timeZoneIdentifier = timeZoneIdentifier
        self.segments = segments.sorted { $0.start < $1.start }
    }

    /// Inserts keeping segments ordered by start time, so two independently
    /// transcribed streams (mic + system) interleave correctly.
    public mutating func append(_ segment: TranscriptSegment) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var segment = segment
        segment.text = text
        let index = segments.firstIndex { $0.start > segment.start } ?? segments.endIndex
        segments.insert(segment, at: index)
    }

    public var duration: TimeInterval { segments.map(\.end).max() ?? 0 }

    public var timeZone: TimeZone { timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }

    // MARK: Persistence

    /// The on-disk format: pretty, key-sorted JSON with ISO-8601 dates.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func load(jsonData data: Data) throws -> Transcript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Transcript.self, from: data)
    }

    // MARK: Rendering

    /// Consecutive segments from the same speaker are folded into one turn when
    /// the pause between them is at most `maxGap` seconds.
    public func turns(maxGap: TimeInterval = 4) -> [Turn] {
        var turns: [Turn] = []
        for segment in segments {
            if var last = turns.last, last.speaker == segment.speaker, segment.start - last.end <= maxGap {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(speaker: segment.speaker, start: segment.start, end: segment.end, text: segment.text))
            }
        }
        return turns
    }

    public struct Turn: Sendable, Equatable {
        public var speaker: Speaker
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
    }

    /// `[00:12] Me: text` — one line per turn. This is also the shape handed to
    /// the summarizer, so keep it stable.
    public func plainText(maxGap: TimeInterval = 4) -> String {
        turns(maxGap: maxGap)
            .map { "[\(Self.timestamp($0.start))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }

    public func markdown(title: String? = nil, maxGap: TimeInterval = 4) -> String {
        var out = "# \(title ?? "Transcript")\n\n"
        out += "- Date: \(startedAt.formatted(date: .abbreviated, time: .shortened))\n"
        out += "- Duration: \(Self.timestamp(duration))\n"
        out += "- Locale: \(locale)\n\n"
        for turn in turns(maxGap: maxGap) {
            out += "**\(turn.speaker.label)** `\(Self.timestamp(turn.start))`  \n\(turn.text)\n\n"
        }
        return out
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
