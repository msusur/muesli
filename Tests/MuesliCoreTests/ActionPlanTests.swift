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
        emailDrafts: [
            .init(to: [], subject: "Delay", body: "Hi all"),
            .init(to: ["bob@vendor.com"], subject: "Budget", body: "Attached"),
        ]
    )

    @Test("applied items drop out of the plan and move to alreadyApplied")
    func filters() {
        var ledger = AppliedLedger()
        let first = ActionPlan(notes: notes(generated))
        #expect(first.actions.count == 2 && first.alreadyApplied.isEmpty)

        ledger.record(first.actions[0], externalID: "")
        let second = ActionPlan(notes: notes(generated), ledger: ledger)
        #expect(second.actions.map(\.title) == ["Budget"])
        #expect(second.alreadyApplied.map(\.title) == ["Delay"])
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

    @Test("keys ignore case and spacing but respect the body")
    func keyNormalization() {
        func key(_ subject: String, _ body: String) -> String {
            ActionPlan(notes: notes(.init(emailDrafts: [.init(to: [], subject: subject, body: body)]))).actions[0].key
        }
        #expect(key("Budget  DELAY", "Hi all") == key("budget delay", "hi  all"))
        #expect(key("Budget delay", "Hi all") != key("Budget delay", "Hello"))
    }

    @Test("action items and agreed meetings stay in the notes, but aren't proposed")
    func onlyEmails() {
        let plan = ActionPlan(notes: notes(generated))
        #expect(plan.actions.allSatisfy { $0.kind == .email })
        #expect(notes(generated).markdown().contains("## Meetings agreed\n- Vendor call"))
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
