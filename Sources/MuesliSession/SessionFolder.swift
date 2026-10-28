import Foundation
import MuesliCore

/// The files of one recorded meeting: `~/Muesli/<date-time>/`.
public struct SessionFolder: Sendable, Hashable, Identifiable {
    public static let transcriptFile = "transcript.json"
    public static let notesFile = "notes.json"
    public static let ledgerFile = "applied.json"

    public let url: URL
    public var id: URL { url }

    public init(_ url: URL) { self.url = url }

    /// `~/Muesli`, where sessions go unless the user chooses otherwise.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Muesli", directoryHint: .isDirectory)
    }

    /// `<root>/2026-09-25-143000`.
    public static func new(in root: URL = defaultRoot, startedAt date: Date) -> SessionFolder {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            .replacingOccurrences(of: "T", with: "-")
        return SessionFolder(root.appending(path: stamp, directoryHint: .isDirectory))
    }

    public func file(_ name: String) -> URL { url.appending(path: name) }

    public var hasNotes: Bool { FileManager.default.fileExists(atPath: file(Self.notesFile).path) }

    // MARK: Transcript

    public func saveTranscript(_ transcript: Transcript, title: String?) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try transcript.jsonData().write(to: file(Self.transcriptFile))
        try transcript.markdown(title: title).write(to: file("transcript.md"), atomically: true, encoding: .utf8)
    }

    public func loadTranscript() throws -> Transcript {
        try Transcript.load(jsonData: Data(contentsOf: file(Self.transcriptFile)))
    }

    // MARK: Notes

    public func saveNotes(_ notes: MeetingNotes) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try notes.jsonData().write(to: file(Self.notesFile))
        try notes.markdown().write(to: file("notes.md"), atomically: true, encoding: .utf8)
    }

    public func loadNotes() throws -> MeetingNotes {
        try MeetingNotes.load(jsonData: Data(contentsOf: file(Self.notesFile)))
    }

    // MARK: Which drafts muesli has opened

    public func loadLedger() -> AppliedLedger {
        (try? Data(contentsOf: file(Self.ledgerFile))).flatMap { try? AppliedLedger.load(jsonData: $0) } ?? AppliedLedger()
    }

    public func saveLedger(_ ledger: AppliedLedger) throws {
        try ledger.jsonData().write(to: file(Self.ledgerFile))
    }

    // MARK: Listing

    /// Sessions under `root` that have a transcript, newest first.
    public static func recent(in root: URL = defaultRoot, limit: Int = 10) -> [SessionFolder] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(SessionFolder.init)
            .filter { FileManager.default.fileExists(atPath: $0.file(transcriptFile).path) }
            .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent } // names are timestamps
            .prefix(limit)
            .map { $0 }
    }

    /// A short label for menus: the notes' title if there are notes, else the transcript's first words.
    public func displayTitle() -> String {
        if let notes = try? loadNotes(), !notes.title.isEmpty { return notes.title }
        if let transcript = try? loadTranscript(), let first = transcript.segments.first?.text {
            let words = first.split(separator: " ").prefix(6).joined(separator: " ")
            return words.count < first.count ? words + "…" : words
        }
        return url.lastPathComponent
    }

    /// When the meeting started, from the transcript, falling back to the folder's date.
    public func startedAt() -> Date? {
        if let transcript = try? loadTranscript() { return transcript.startedAt }
        return try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}
