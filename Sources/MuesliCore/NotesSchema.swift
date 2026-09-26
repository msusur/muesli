import Foundation

/// A tiny, backend-neutral description of the JSON shape we ask models for.
///
/// Every backend needs the same structure in a different dress: Claude and
/// OpenAI-compatible servers take a JSON Schema, Apple's Foundation Models take
/// a `DynamicGenerationSchema`. Defining it once here keeps them from drifting.
///
/// Rules that keep it portable across strict structured-output modes: every
/// property is required, objects forbid extras, and "unknown" is an empty
/// string / empty array rather than `null`.
public indirect enum SchemaNode: Sendable, Equatable {
    case string
    case integer
    case array(SchemaNode)
    case object(name: String, properties: [SchemaProperty])
}

public struct SchemaProperty: Sendable, Equatable {
    public var name: String
    public var description: String
    public var node: SchemaNode

    public init(_ name: String, _ description: String, _ node: SchemaNode) {
        self.name = name
        self.description = description
        self.node = node
    }
}

extension SchemaNode {
    /// JSON Schema (draft 2020-12 subset), with properties in declaration order.
    public func jsonSchema(description: String? = nil) -> JSONValue {
        var members: [JSONValue.Member] = []
        switch self {
        case .string:
            members.append(.init("type", .string("string")))
        case .integer:
            members.append(.init("type", .string("integer")))
        case .array(let item):
            members.append(.init("type", .string("array")))
            members.append(.init("items", item.jsonSchema()))
        case .object(_, let properties):
            members.append(.init("type", .string("object")))
            members.append(.init("properties", .object(properties.map {
                .init($0.name, $0.node.jsonSchema(description: $0.description))
            })))
            members.append(.init("required", .array(properties.map { .string($0.name) })))
            members.append(.init("additionalProperties", .bool(false)))
        }
        if let description { members.append(.init("description", .string(description))) }
        return .object(members)
    }
}

/// The shape of a set of meeting notes as models produce it.
public enum NotesSchema {
    public static let name = "MeetingNotes"

    public static let root: SchemaNode = .object(name: name, properties: [
        .init("title", "A short descriptive title for the meeting, at most 8 words.", .string),
        .init("summary", "A 2-4 sentence overview: what was discussed and what was concluded.", .string),
        .init("keyPoints", "The most important points discussed, in the order they came up. One sentence each.", .array(.string)),
        .init("decisions", "Decisions that were actually made. One sentence each. Empty if none.", .array(.string)),
        .init("actionItems", "Concrete things someone committed to do or was asked to do. Empty if none.", .array(actionItem)),
        .init("events", "Meetings, calls or appointments that were agreed and belong in a calendar. Empty if none.", .array(event)),
        .init("emailDrafts", "Follow-up emails that were requested or are clearly needed. Empty if none.", .array(email)),
        .init("openQuestions", "Questions raised but not answered. Empty if none.", .array(.string)),
        .init("enhancedNotes", "If the user wrote notes: their notes as clean markdown, each point expanded with detail from the transcript. Otherwise an empty string.", .string),
    ])

    static let actionItem: SchemaNode = .object(name: "ActionItem", properties: [
        .init("title", "One short imperative sentence, e.g. \"Send the revised budget to finance\".", .string),
        .init("owner", "\"Me\" if the user is responsible, the person's name if the transcript names them, otherwise an empty string.", .string),
        .init("dueDate", "The deadline as YYYY-MM-DD, resolved from the calendar you were given. Empty string if none or uncertain.", .string),
        .init("dueText", "The words used for the deadline, e.g. \"by Monday\". Empty string if none.", .string),
        .init("context", "One short sentence of context so the item makes sense later. Empty string if unnecessary.", .string),
    ])

    static let event: SchemaNode = .object(name: "CalendarEvent", properties: [
        .init("title", "Short event title.", .string),
        .init("start", "YYYY-MM-DDTHH:MM (24-hour, meeting timezone) if a time was given, YYYY-MM-DD if only a day, otherwise an empty string.", .string),
        .init("durationMinutes", "Length in minutes, or 0 if unknown.", .integer),
        .init("attendees", "Names of people to invite, as spoken. Empty if none.", .array(.string)),
    ])

    static let email: SchemaNode = .object(name: "EmailDraft", properties: [
        .init("to", "Recipient names or addresses exactly as spoken. Never invent an address.", .array(.string)),
        .init("subject", "Concise subject line.", .string),
        .init("body", "The email body, written as the user, short and natural, ending with a sign-off but no name.", .string),
    ])

    public static func jsonSchema() -> JSONValue { root.jsonSchema() }
}
