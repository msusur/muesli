import Foundation

public struct GenerationResult: Sendable {
    public var notes: GeneratedNotes
    public var usage: TokenUsage

    public init(notes: GeneratedNotes, usage: TokenUsage = TokenUsage()) {
        self.notes = notes
        self.usage = usage
    }
}

/// One way of turning a prompt into structured notes: Apple's on-device model,
/// Apple Private Cloud Compute, Claude, or any OpenAI-compatible server
/// (llama.cpp, Ollama, LM Studio…). Backends only implement one request;
/// chunking and merging live in `MeetingSummarizer`.
public protocol NotesGenerator: Sendable {
    /// Shown to the user and stored as provenance, e.g. "anthropic:claude-opus-5".
    var displayName: String { get }

    /// The most transcript text, in characters, to put in a single request,
    /// after leaving room for the prompt and the reply.
    var transcriptCharacterBudget: Int { get async }

    /// Cheap checks to run before recording or summarizing: a missing API key,
    /// a model that isn't downloaded, a context window that's too small. Should
    /// throw an error whose message tells the user how to fix it.
    func preflight() async throws

    func generate(system: String, user: String) async throws -> GenerationResult
}

extension NotesGenerator {
    public func preflight() async throws {}
}

public struct SummaryResult: Sendable {
    public var notes: MeetingNotes
    public var usage: TokenUsage
    /// Number of model requests made (1 for a short meeting).
    public var requests: Int
}

public struct MeetingSummarizer: Sendable {
    public let generator: any NotesGenerator

    /// Give up merging after this many rounds; only a pathologically small
    /// context window could need more.
    private let maxMergeRounds = 6

    /// Below this a long meeting would need hundreds of requests.
    static let minimumBudget = 1_000

    public init(generator: any NotesGenerator) {
        self.generator = generator
    }

    public func summarize(_ transcript: Transcript, context: MeetingContext) async throws -> SummaryResult {
        let lines = transcript.turns().map {
            "[\(Transcript.timestamp($0.start))] \($0.speaker.label): \($0.text)"
        }
        guard !lines.isEmpty else { throw SummarizeError.emptyTranscript }

        let budget = await generator.transcriptCharacterBudget
        guard budget >= Self.minimumBudget else { throw SummarizeError.contextTooSmall(characters: budget) }
        var usage = TokenUsage()
        var requests = 0

        func run(_ user: String) async throws -> GeneratedNotes {
            let result = try await generator.generate(system: Prompts.system, user: user)
            usage = usage + result.usage
            requests += 1
            return result.notes
        }

        let whole = lines.joined(separator: "\n")
        let final: GeneratedNotes
        if whole.count <= budget {
            final = try await run(Prompts.single(transcript: whole, context: context))
        } else {
            let chunks = TranscriptChunker.chunks(lines: lines, maxCharacters: budget)
            var partials: [GeneratedNotes] = []
            for (i, chunk) in chunks.enumerated() {
                partials.append(try await run(Prompts.part(i + 1, of: chunks.count, transcript: chunk, context: context)))
            }
            final = try await merge(partials, context: context, budget: budget, run: run)
        }

        return SummaryResult(
            notes: MeetingNotes(normalizing: final, context: context, generatedBy: generator.displayName),
            usage: usage,
            requests: requests
        )
    }

    /// Repeatedly merges groups of partial notes until one set remains. The
    /// last round is the only one that sees the user's notes.
    private func merge(
        _ initial: [GeneratedNotes], context: MeetingContext, budget: Int,
        run: (String) async throws -> GeneratedNotes
    ) async throws -> GeneratedNotes {
        var partials = initial
        var rounds = 0
        while true {
            rounds += 1
            var groups = Self.group(partials, budget: budget)
            // Either everything fits in one request, or we're out of patience
            // or the parts are so big nothing can be grouped: merge it all at once.
            if groups.count == 1 || groups.count >= partials.count || rounds >= maxMergeRounds {
                groups = [partials]
            }
            let isFinal = groups.count == 1
            var next: [GeneratedNotes] = []
            for group in groups {
                next.append(try await run(Prompts.merge(group, context: context, isFinal: isFinal)))
            }
            if isFinal { return next[0] }
            partials = next
        }
    }

    static func group(_ parts: [GeneratedNotes], budget: Int) -> [[GeneratedNotes]] {
        var groups: [[GeneratedNotes]] = []
        var current: [GeneratedNotes] = []
        var size = 0
        for part in parts {
            let s = Prompts.mergeSize(of: part)
            if !current.isEmpty, size + s > budget {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(part)
            size += s
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
