import Foundation
import FoundationModels
import MuesliCore

/// Apple Intelligence: the on-device model, or (macOS 27+) the larger model on
/// Private Cloud Compute. No API key and no per-token cost.
///
/// Structured output uses a `DynamicGenerationSchema` built at runtime from
/// `NotesSchema`, rather than an `@Generable` struct, so the notes format is
/// defined once for every backend.
@available(macOS 26.0, *)
public struct AppleGenerator: NotesGenerator {
    public enum Kind: String, Sendable {
        case onDevice = "on-device"
        case privateCloud = "private-cloud"
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var displayName: String { "apple:\(kind.rawValue)" }

    // MARK: Availability

    /// `nil` when the model can be used; otherwise a sentence saying why not and what to do.
    public static func unavailableReason(_ kind: Kind) -> String? {
        switch kind {
        case .onDevice:
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri."
            case .unavailable(.modelNotReady):
                return "The on-device model isn't ready yet; it may still be downloading. Try again later."
            case .unavailable: return "The on-device model is unavailable."
            }
        case .privateCloud:
            guard #available(macOS 27.0, *) else { return "Private Cloud Compute needs macOS 27 or later." }
            switch PrivateCloudComputeLanguageModel().availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This Mac can't use Private Cloud Compute."
            case .unavailable(.systemNotReady):
                return "Private Cloud Compute isn't ready yet (sign-in, network or Apple Intelligence setup may be incomplete). Try again later."
            case .unavailable: return "Private Cloud Compute is unavailable."
            }
        }
    }

    /// The model's context window in tokens, or nil if it can't be determined.
    public func contextTokens() async -> Int? {
        switch kind {
        case .onDevice:
            let n = SystemLanguageModel.default.contextSize
            return n > 0 ? n : nil
        case .privateCloud:
            guard #available(macOS 27.0, *) else { return nil }
            return try? await PrivateCloudComputeLanguageModel().contextSize
        }
    }

    public func preflight() async throws {
        if let reason = Self.unavailableReason(kind) { throw BackendError.unavailable(reason) }
        guard let tokens = await contextTokens() else {
            throw BackendError.unavailable(
                "Couldn't read the \(kind.rawValue) model's context window. Check your connection and Apple Intelligence setup, then try again.")
        }
        if ContextBudget.characters(contextTokens: tokens) < ContextBudget.minimumUseful {
            throw BackendError.unavailable(
                "The \(kind.rawValue) model's context window (\(tokens) tokens) is too small for muesli's notes format. Use --backend apple-cloud, a local server, or a cloud model.")
        }
    }

    public var transcriptCharacterBudget: Int {
        get async {
            // If the window is unknown or tiny, `preflight` has already refused; the
            // floor just stops a caller that skipped it from making thousands of requests.
            max(ContextBudget.minimumUseful, ContextBudget.characters(contextTokens: await contextTokens() ?? 0))
        }
    }

    // MARK: Generation

    public func generate(system: String, user: String) async throws -> GenerationResult {
        if let reason = Self.unavailableReason(kind) { throw BackendError.unavailable(reason) }
        let schema = try GenerationSchema(root: Self.dynamicSchema(NotesSchema.root), dependencies: [])
        // Deterministic: this is extraction, not creative writing.
        let options = GenerationOptions(samplingMode: .greedy)

        let json: String
        switch kind {
        case .onDevice:
            // Summarizing text the user already has is a "content transformation";
            // the permissive guardrail mode avoids false refusals on ordinary
            // meeting content (health, legal, finance, conflict).
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            json = try await Self.respond(with: model, system: system, user: user, schema: schema, options: options)
        case .privateCloud:
            guard #available(macOS 27.0, *) else { throw BackendError.unavailable("Private Cloud Compute needs macOS 27 or later.") }
            json = try await Self.respond(with: PrivateCloudComputeLanguageModel(), system: system, user: user, schema: schema, options: options)
        }
        return GenerationResult(notes: try GeneratedNotes.parse(json))
    }

    private static func respond(
        with model: SystemLanguageModel, system: String, user: String,
        schema: GenerationSchema, options: GenerationOptions
    ) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: system)
        return try await session.respond(to: user, schema: schema, options: options).content.jsonString
    }

    @available(macOS 27.0, *)
    private static func respond(
        with model: PrivateCloudComputeLanguageModel, system: String, user: String,
        schema: GenerationSchema, options: GenerationOptions
    ) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: system)
        return try await session.respond(to: user, schema: schema, options: options).content.jsonString
    }

    static func dynamicSchema(_ node: SchemaNode) -> DynamicGenerationSchema {
        switch node {
        case .string:
            DynamicGenerationSchema(type: String.self)
        case .integer:
            DynamicGenerationSchema(type: Int.self)
        case .array(let item):
            DynamicGenerationSchema(arrayOf: dynamicSchema(item))
        case .object(let name, let properties):
            DynamicGenerationSchema(name: name, properties: properties.map {
                DynamicGenerationSchema.Property(name: $0.name, description: $0.description, schema: dynamicSchema($0.node))
            })
        }
    }
}
