import Foundation

extension MeetingNotes {
    /// Human-readable notes. Action items use `- [ ]` so they work as
    /// checklists in Obsidian, Notes and GitHub.
    public func markdown() -> String {
        var out = "# \(title)\n\n"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        formatter.dateFormat = "EEE d MMM yyyy, HH:mm"
        out += "_\(formatter.string(from: meetingStart)) · \(generatedBy)_\n\n"

        if !summary.isEmpty { out += "## Summary\n\(summary)\n\n" }
        if let enhancedNotes, !enhancedNotes.isEmpty { out += "## Notes\n\(enhancedNotes)\n\n" }
        if !keyPoints.isEmpty { out += "## Key points\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !decisions.isEmpty { out += "## Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }

        if !actionItems.isEmpty {
            out += "## Action items\n"
            for item in actionItems {
                var details: [String] = []
                if let owner = item.owner { details.append(owner) }
                if let due = item.dueDate {
                    details.append("due \(due)" + (item.dueText.map { " (\($0))" } ?? ""))
                } else if let text = item.dueText {
                    details.append("“\(text)”")
                }
                out += "- [ ] \(item.title)" + (details.isEmpty ? "" : " — " + details.joined(separator: " · ")) + "\n"
                if let context = item.context { out += "  - \(context)\n" }
            }
            out += "\n"
        }

        if !events.isEmpty {
            out += "## Meetings agreed\n"
            for e in events {
                var line = "- \(e.title)"
                if let start = e.start { line += " — \(start.replacingOccurrences(of: "T", with: " "))" }
                if let minutes = e.durationMinutes { line += " (\(minutes) min)" }
                if !e.attendees.isEmpty { line += " with " + e.attendees.joined(separator: ", ") }
                out += line + "\n"
            }
            out += "\n"
        }

        if !emailDrafts.isEmpty {
            out += "## Email drafts\n"
            for m in emailDrafts {
                out += "### \(m.subject.isEmpty ? "(no subject)" : m.subject)\n"
                if !m.to.isEmpty { out += "To: \(m.to.joined(separator: ", "))\n\n" }
                out += m.body + "\n\n"
            }
        }

        if !openQuestions.isEmpty { out += "## Open questions\n" + openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
