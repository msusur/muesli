import Foundation
import MuesliCore

/// The files of one recorded meeting: `~/Muesli/<date-time>/`, or
/// `~/Muesli/<date-time> <name>/` once it has been renamed.
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
        SessionFolder(root.appending(path: stamp(for: date), directoryHint: .isDirectory))
    }

    /// `2026-09-25-143000`, in UTC, so folder names sort by time.
    static func stamp(for date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            .replacingOccurrences(of: "T", with: "-")
    }

    /// The `2026-09-25-143000` the folder's name starts with, if it does.
    private var stamp: String? {
        let name = url.lastPathComponent
        guard let match = name.prefixMatch(of: /\d{4}-\d{2}-\d{2}-\d{6}/) else { return nil }
        return String(match.output)
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

    // MARK: Naming

    /// The name the user gave the meeting: what follows the timestamp in the folder's name.
    public var name: String? {
        guard let stamp else { return nil }
        let rest = url.lastPathComponent.dropFirst(stamp.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    public enum RenameError: LocalizedError {
        case alreadyExists(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyExists(let name): "There's already a meeting folder called “\(name)”."
            }
        }
    }

    /// Names the meeting: the folder becomes `<date-time> <name>` (just
    /// `<date-time>` for an empty name, which undoes a rename), and the titles
    /// in transcript.md and the notes follow. Returns the moved folder.
    public func rename(to newName: String) throws -> SessionFolder {
        let name = Self.cleanName(newName)
        let stamp = stamp ?? Self.stamp(for: startedAt() ?? Date())
        let folderName = name.isEmpty ? stamp : "\(stamp) \(name)"
        let renamed = SessionFolder(url.deletingLastPathComponent().appending(path: folderName, directoryHint: .isDirectory))

        if renamed.url.standardizedFileURL != url.standardizedFileURL {
            // Only a case change: same folder on a case-insensitive disk, so it can't clash.
            let caseOnly = folderName.lowercased() == url.lastPathComponent.lowercased()
            if !caseOnly, FileManager.default.fileExists(atPath: renamed.url.path) { throw RenameError.alreadyExists(folderName) }
            try FileManager.default.moveItem(at: url, to: renamed.url)
        }

        if let transcript = try? renamed.loadTranscript() {
            try transcript.markdown(title: name.isEmpty ? nil : name).write(to: renamed.file("transcript.md"), atomically: true, encoding: .utf8)
        }
        if !name.isEmpty, var notes = try? renamed.loadNotes() {
            notes.title = name
            try renamed.saveNotes(notes)
        }
        return renamed
    }

    /// One line, without the characters a folder name can't hold.
    static func cleanName(_ name: String) -> String {
        let parts = name.components(separatedBy: CharacterSet(charactersIn: "/:").union(.newlines).union(.controlCharacters))
        var out = parts.joined(separator: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while out.hasPrefix(".") { out.removeFirst() } // no hidden folders
        return String(out.prefix(120)).trimmingCharacters(in: .whitespaces)
    }

    /// A short label for menus: the name the user gave it, else the notes'
    /// title if there are notes, else the transcript's first words.
    public func displayTitle() -> String {
        if let name { return name }
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
