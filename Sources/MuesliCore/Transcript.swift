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
    /// Absent in files without annotations, and in older files.
    private var storedAnnotations: [Annotation]?

    /// A personal note on a moment of the meeting.
    public struct Annotation: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        /// Seconds since the session started: the start of the line it's on.
        public var at: TimeInterval
        public var text: String

        public init(id: UUID = UUID(), at: TimeInterval, text: String) {
            self.id = id
            self.at = at
            self.text = text
        }
    }

    enum CodingKeys: String, CodingKey {
        case startedAt, locale, timeZoneIdentifier, segments
        case storedAnnotations = "annotations"
    }

    public init(
        startedAt: Date = Date(), locale: String, timeZoneIdentifier: String? = TimeZone.current.identifier,
        segments: [TranscriptSegment] = [], annotations: [Annotation] = []
    ) {
        self.startedAt = startedAt
        self.locale = locale
        self.timeZoneIdentifier = timeZoneIdentifier
        self.segments = segments.sorted { $0.start < $1.start }
        self.annotations = annotations
    }

    /// Ordered by when in the meeting they're about.
    public var annotations: [Annotation] {
        get { storedAnnotations ?? [] }
        set { storedAnnotations = newValue.isEmpty ? nil : newValue.sorted { $0.at < $1.at } }
    }

    /// The same meeting with only some of its lines and annotations, e.g. what
    /// hasn't been copied yet.
    public func filtered(segments keepSegment: (TranscriptSegment) -> Bool, annotations keepAnnotation: (Annotation) -> Bool) -> Transcript {
        Transcript(startedAt: startedAt, locale: locale, timeZoneIdentifier: timeZoneIdentifier,
                   segments: segments.filter(keepSegment), annotations: annotations.filter(keepAnnotation))
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
    /// the pause between them is at most `maxGap` seconds; `nil` keeps every
    /// segment as its own turn.
    public func turns(maxGap: TimeInterval? = 4) -> [Turn] {
        var turns: [Turn] = []
        for segment in segments {
            if let maxGap, var last = turns.last, last.speaker == segment.speaker, segment.start - last.end <= maxGap {
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

    public func markdown(title: String? = nil, maxGap: TimeInterval? = 4) -> String {
        var out = "# \(title ?? "Transcript")\n\n"
        out += "- Date: \(startedAt.formatted(date: .abbreviated, time: .shortened))\n"
        out += "- Duration: \(Self.timestamp(duration))\n"
        out += "- Locale: \(locale)\n\n"
        return out + markdownBody(maxGap: maxGap)
    }

    /// The turns, with annotations after the turn they're on, as in
    /// transcript.md but without its heading and details.
    public func markdownBody(maxGap: TimeInterval? = 4) -> String {
        var out = ""
        var pending = annotations[...]
        func emitAnnotations(before time: TimeInterval?) {
            while let next = pending.first, time.map({ next.at < $0 }) ?? true {
                let clock = clockTime(startedAt.addingTimeInterval(next.at))
                let text = next.text.replacingOccurrences(of: "\n", with: "  \n> ")
                out += "> **Note** `\(Self.timestamp(next.at))` (\(clock))  \n> \(text)\n\n"
                pending.removeFirst()
            }
        }
        let turns = turns(maxGap: maxGap)
        // Notes from before anything was said come first.
        emitAnnotations(before: turns.first?.start)
        for (i, turn) in turns.enumerated() {
            let clock = clockTime(startedAt.addingTimeInterval(turn.start))
            out += "**\(turn.speaker.label)** `\(Self.timestamp(turn.start))` (\(clock))  \n\(turn.text)\n\n"
            emitAnnotations(before: i + 1 < turns.count ? turns[i + 1].start : nil)
        }
        return out
    }

    /// Time of day in the meeting's time zone, e.g. "11:48am".
    func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter.string(from: date)
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
