import Foundation
import Testing
@testable import MuesliCore

private let london = TimeZone(identifier: "Europe/London")!

private func meetingStart() -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = london
    return cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 14, minute: 30))!
}

private func notes(_ g: GeneratedNotes, title: String = "Launch sync") -> MeetingNotes {
    var g = g
    g.title = title
    return MeetingNotes(normalizing: g, context: MeetingContext(start: meetingStart(), timeZone: london), generatedBy: "test")
}

private func utc(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

// MARK: - Reminders

@Suite("Action plan: reminders")
struct ReminderPlanTests {
    @Test("your own tasks are selected; other people's become 'waiting on' reminders, unselected")
    func ownership() throws {
        let plan = ActionPlan(notes: notes(.init(actionItems: [
            .init(title: "Send the budget", owner: "Me", dueDate: "2026-09-28", dueText: "by Monday", context: "Finance needs it."),
            .init(title: "Review the contract", owner: "Sarah"),
            .init(title: "Ping legal", owner: ""),
        ])))
        let r = plan.actions.filter { $0.kind == .reminder }
        #expect(r.map(\.selectedByDefault) == [true, false, true])
        #expect(r[1].title == "Waiting on Sarah: Review the contract")

        guard case .reminder(let req) = r[0].payload else { Issue.record("not a reminder"); return }
        #expect(req.title == "Send the budget")
        #expect(req.due == DateComponents(year: 2026, month: 9, day: 28))
        #expect(req.notes.contains("Finance needs it."))
        #expect(req.notes.contains("Said: “by Monday”"))
        #expect(req.notes.contains("From “Launch sync” (Fri 25 Sep 2026), created by muesli."))
        #expect(r[0].detail == "due Mon 28 Sep · Me")
    }

    @Test("an unresolved date is explained, not silently dropped")
    func noDate() throws {
        let plan = ActionPlan(notes: notes(.init(actionItems: [.init(title: "Follow up", owner: "Me", dueDate: "2026-02-31", dueText: "soon")])))
        let action = try #require(plan.actions.first)
        guard case .reminder(let req) = action.payload else { Issue.record("not a reminder"); return }
        #expect(req.due == nil)
        #expect(action.detail == "no date resolved (“soon”) · Me")
        #expect(req.notes.contains("Said: “soon”"))
    }
}

// MARK: - Events

@Suite("Action plan: events")
struct EventPlanTests {
    private func event(_ g: GeneratedNotes.Event) throws -> (ProposedAction, EventRequest) {
        let plan = ActionPlan(notes: notes(.init(events: [g])))
        let action = try #require(plan.actions.first { $0.kind == .event })
        guard case .event(let req) = action.payload else { throw CancellationError() }
        return (action, req)
    }

    @Test("a timed event lands at the right instant in the meeting's time zone (BST)")
    func timedBST() throws {
        let (action, req) = try event(.init(title: "Vendor call", start: "2026-10-02T15:00", attendees: ["Bob"]))
        #expect(!req.isAllDay)
        #expect(req.start == utc("2026-10-02T14:00:00Z")) // 15:00 BST = 14:00Z
        #expect(req.end == utc("2026-10-02T14:30:00Z")) // 30 minutes when unspecified
        #expect(req.timeZone == london)
        #expect(req.notes.contains("With: Bob"))
        #expect(action.detail == "Fri 2 Oct, 15:00–15:30 · with Bob")
    }

    @Test("across the clock change the same wall time maps to a different UTC hour")
    func timedGMT() throws {
        let (_, req) = try event(.init(title: "After the change", start: "2026-10-26T15:00", durationMinutes: 45))
        #expect(req.start == utc("2026-10-26T15:00:00Z")) // GMT again after 25 Oct
        #expect(req.end == utc("2026-10-26T15:45:00Z"))
    }

    @Test("a date without a time becomes an all-day event")
    func allDay() throws {
        let (action, req) = try event(.init(title: "Offsite", start: "2026-10-03"))
        #expect(req.isAllDay)
        #expect(req.start == utc("2026-10-02T23:00:00Z")) // midnight 3 Oct in London
        #expect(action.detail == "Sat 3 Oct (all day)")
    }

    @Test("an event with no start is skipped with a reason")
    func skipped() {
        let plan = ActionPlan(notes: notes(.init(events: [.init(title: "Sometime", start: "")])))
        #expect(plan.actions.isEmpty)
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped[0].title == "Sometime")
        #expect(plan.skipped[0].reason.contains("no date or time"))
    }
}

// MARK: - Emails

@Suite("Action plan: emails")
struct EmailPlanTests {
    @Test("only real addresses become recipients; names are flagged")
    func recipients() throws {
        let plan = ActionPlan(notes: notes(.init(emailDrafts: [
            .init(to: ["bob@vendor.com", "Board"], subject: "Delay", body: "Hi all"),
            .init(to: [], subject: "", body: "Note to self"),
        ])))
        let emails = plan.actions.filter { $0.kind == .email }
        #expect(emails.count == 2)
        #expect(emails[0].detail == "to bob@vendor.com · add an address for Board")
        guard case .email(let req) = emails[0].payload else { Issue.record("not an email"); return }
        #expect(req.recipients == ["bob@vendor.com"] && req.unresolvedNames == ["Board"])
        #expect(emails[1].title == "(no subject)")
        #expect(emails[1].detail == "no recipient address yet")
        #expect(emails.allSatisfy { $0.selectedByDefault })
    }
}

// MARK: - Ledger

@Suite("Applied ledger")
struct LedgerTests {
    private let generated = GeneratedNotes(
        actionItems: [.init(title: "Send the budget", owner: "Me", dueDate: "2026-09-28")],
        events: [.init(title: "Vendor call", start: "2026-10-02T15:00")],
        emailDrafts: [.init(to: [], subject: "Delay", body: "Hi all")]
    )

    @Test("applied items drop out of the plan and move to alreadyApplied")
    func filters() {
        var ledger = AppliedLedger()
        let first = ActionPlan(notes: notes(generated))
        #expect(first.actions.count == 3 && first.alreadyApplied.isEmpty)

        ledger.record(first.actions[0], externalID: "REM-1")
        let second = ActionPlan(notes: notes(generated), ledger: ledger)
        #expect(second.actions.count == 2)
        #expect(second.alreadyApplied.map(\.title) == ["Send the budget"])
    }

    @Test("re-summarizing (new item UUIDs) doesn't defeat the ledger")
    func stableKeys() {
        let a = ActionPlan(notes: notes(generated))
        let b = ActionPlan(notes: notes(generated))
        #expect(a.actions.map(\.id) != b.actions.map(\.id))
        #expect(a.actions.map(\.key) == b.actions.map(\.key))

        var ledger = AppliedLedger()
        for action in a.actions { ledger.record(action, externalID: "x") }
        #expect(ActionPlan(notes: notes(generated), ledger: ledger).actions.isEmpty)
    }

    @Test("keys ignore case and spacing but respect the date")
    func keyNormalization() {
        func key(_ title: String, _ due: String) -> String {
            ActionPlan(notes: notes(.init(actionItems: [.init(title: title, dueDate: due)]))).actions[0].key
        }
        #expect(key("Send  the BUDGET", "2026-09-28") == key("send the budget", "2026-09-28"))
        #expect(key("Send the budget", "2026-09-28") != key("Send the budget", "2026-09-29"))
    }

    @Test("recording twice replaces; remove works; JSON round-trips")
    func mutation() throws {
        let action = ActionPlan(notes: notes(generated)).actions[0]
        var ledger = AppliedLedger()
        ledger.record(action, externalID: "A", at: Date(timeIntervalSince1970: 1_700_000_000))
        ledger.record(action, externalID: "B", at: Date(timeIntervalSince1970: 1_700_000_100))
        #expect(ledger.entries.count == 1 && ledger.entries[0].externalID == "B")

        let back = try AppliedLedger.load(jsonData: ledger.jsonData())
        #expect(back == ledger)
        ledger.remove(key: action.key)
        #expect(ledger.entries.isEmpty)
    }
}

// MARK: - Review prompt

@Suite("Review selection")
struct SelectionTests {
    @Test("empty input keeps the defaults; all/none work")
    func basics() {
        #expect(ReviewSelection.parse("", count: 4, defaults: [1, 3]) == [1, 3])
        #expect(ReviewSelection.parse("  ", count: 4, defaults: [2]) == [2])
        #expect(ReviewSelection.parse("a", count: 3, defaults: []) == [1, 2, 3])
        #expect(ReviewSelection.parse("ALL", count: 3, defaults: []) == [1, 2, 3])
        #expect(ReviewSelection.parse("n", count: 3, defaults: [1]) == [])
        #expect(ReviewSelection.parse("q", count: 3, defaults: [1]) == [])
    }

    @Test("numbers, lists and ranges")
    func numbers() {
        #expect(ReviewSelection.parse("2", count: 5, defaults: []) == [2])
        #expect(ReviewSelection.parse("1,3 5", count: 5, defaults: []) == [1, 3, 5])
        #expect(ReviewSelection.parse("2-4", count: 5, defaults: []) == [2, 3, 4])
        #expect(ReviewSelection.parse("1, 3-4", count: 5, defaults: []) == [1, 3, 4])
    }

    @Test("anything unclear is rejected so the caller can ask again")
    func invalid() {
        for bad in ["0", "6", "x", "3-2", "1-9", "1--2", ",", "1,x"] {
            #expect(ReviewSelection.parse(bad, count: 5, defaults: [1]) == nil, "\(bad)")
        }
        #expect(ReviewSelection.parse("1", count: 0, defaults: [1]) == [])
    }
}

// MARK: - Mail drafts

@Suite("Mail drafts")
struct MailTests {
    @Test("recognizes addresses and rejects names")
    func addresses() {
        for ok in ["a@b.co", "first.last+tag@sub.example.com"] { #expect(MailDraft.isEmailAddress(ok), "\(ok)") }
        for bad in ["Board", "bob@", "@vendor.com", "bob@vendor", "bob @vendor.com", "a@b@c.com", "bob@.com", "bob@vendor."] {
            #expect(!MailDraft.isEmailAddress(bad), "\(bad)")
        }
    }

    private func decode(_ url: URL) -> (path: String, items: [String: String]) {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items: [String: String] = [:]
        for q in c.queryItems ?? [] { items[q.name] = q.value }
        return (c.percentEncodedPath.removingPercentEncoding ?? c.path, items)
    }

    @Test("subject and body survive awkward characters round-trip")
    func roundTrip() throws {
        let subject = "Q3 & Q4: 100% done? #launch"
        let body = "Hi all,\n\nSee \"the plan\" — it's ready. Cost: £1,200 + VAT 🚀\n\nBest,"
        let url = try #require(MailDraft.mailtoURL(to: ["bob+work@vendor.com", "sarah@x.io"], subject: subject, body: body))
        #expect(url.scheme == "mailto")

        let (path, items) = decode(url)
        #expect(path == "bob+work@vendor.com,sarah@x.io")
        #expect(items["subject"] == subject)
        #expect(items["body"] == body.replacingOccurrences(of: "\n", with: "\r\n"))
        // Nothing that could break the URL structure is left raw.
        let raw = url.absoluteString
        #expect(!raw.dropFirst("mailto:".count).contains(" ") && !raw.contains("\n") && !raw.contains("\""))
        #expect(raw.filter { $0 == "?" }.count == 1)
        #expect(raw.filter { $0 == "&" }.count == 1)
    }

    @Test("names are never put in the To field")
    func namesDropped() throws {
        let url = try #require(MailDraft.mailtoURL(to: ["Board", "bob@vendor.com"], subject: "S", body: "B"))
        #expect(decode(url).path == "bob@vendor.com")
        let none = try #require(MailDraft.mailtoURL(to: ["Board"], subject: "S", body: "B"))
        #expect(none.absoluteString.hasPrefix("mailto:?subject=S"))
    }

    @Test("empty parts are omitted")
    func empties() throws {
        #expect(MailDraft.mailtoURL(to: [], subject: "", body: "")?.absoluteString == "mailto:")
        #expect(MailDraft.mailtoURL(to: ["a@b.co"], subject: "Hi", body: "")?.absoluteString == "mailto:a@b.co?subject=Hi")
    }

    @Test("markup and shell metacharacters are inert, plain percent-encoded text")
    func inert() throws {
        let nasty = "\"; do shell script \"rm -rf ~\" -- $(whoami) `id` \\ <script>"
        let url = try #require(MailDraft.mailtoURL(to: [], subject: nasty, body: nasty))
        #expect(decode(url).items["subject"] == nasty)
        #expect(!url.absoluteString.contains("$(") && !url.absoluteString.contains("`") && !url.absoluteString.contains("<"))
    }
}
