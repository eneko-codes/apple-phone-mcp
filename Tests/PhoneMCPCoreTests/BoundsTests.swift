import Foundation
import Testing

@testable import PhoneMCPCore

/// The edges of the tool standard for this server's tools: each bound and one past it, the
/// text of each notice, pages that chain, the longest result, the deadline, and the texts
/// the model reads. Every number, name and date in here is invented.
@Suite("Bounds")
struct BoundsTests {

    // MARK: Invented history

    /// The widest ordinary party of a row: a contact name of 40 characters and a number.
    private static let longName = "Ane Example-Longname Invented Contact 01"
    private static let number = "+12125550101"

    private static func book() -> FakeContactResolver {
        let contacts = FakeContactResolver()
        contacts.contacts = [(name: longName, addresses: [number])]
        return contacts
    }

    /// `count` calls, call `index` being `index + 1` minutes older than the first, so the
    /// listing order is the order of the ids.
    private static func history(_ count: Int, group: Int = 1) -> FakeCallStore {
        let store = FakeCallStore()
        let base = Fixtures.date(2026, 8, 12, 21, 0)
        store.callsValue = (0..<count).map {
            Fixtures.call(
                id: Int64($0 + 1), at: base.addingTimeInterval(Double(-$0) * 60),
                direction: .outgoing, kind: .facetimeVideo, duration: 3_725,
                with: Array(repeating: number, count: 1) + (1..<max(group, 1)).map { "ane\($0)@example.com" })
        }
        return store
    }

    private static func call(
        _ name: String, _ arguments: [String: Value] = [:], store: FakeCallStore,
        contacts: FakeContactResolver = book(), timeout: Duration = PhoneTools.defaultTimeout
    ) async -> (text: String, isError: Bool) {
        let tools = PhoneTools(
            store: store, contacts: contacts, calendar: Fixtures.calendar, timeout: timeout)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text) = result.content.first else { return ("(no text)", true) }
        return (text, result.isError)
    }

    /// The ids of the rows a listing shows, in order.
    private static func ids(in text: String) -> [Int] {
        text.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: " · id ") else { return nil }
            return Int(line[range.upperBound...])
        }
    }

    // MARK: calls_list pages

    @Test("A call with no optional argument returns one default page, announced before the data")
    func defaultPage() async {
        let total = ToolCatalog.defaultListLimit + 5
        let result = await Self.call(ToolCatalog.listName, store: Self.history(total))
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(ToolCatalog.defaultListLimit) of \(total) calls. Pass offset=\(ToolCatalog.defaultListLimit) for the next page.\n\n"))
        #expect(Self.ids(in: result.text) == Array(1...ToolCatalog.defaultListLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every call from the start carries no notice")
    func wholeListingHasNoNotice() async {
        let result = await Self.call(
            ToolCatalog.listName, store: Self.history(ToolCatalog.defaultListLimit))
        #expect(Self.ids(in: result.text).count == ToolCatalog.defaultListLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result")
    func limitAtItsMaximum() async {
        let maximum = ToolCatalog.listLimitRange.upperBound
        let result = await Self.call(
            ToolCatalog.listName, ["limit": .int(maximum)], store: Self.history(maximum + 10))
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(maximum + 10) calls. Pass offset=\(maximum) for the next page.\n\n"))
        #expect(Self.ids(in: result.text) == Array(1...maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        // The default page of the same rows is about one usual page or less.
        let usual = await Self.call(ToolCatalog.listName, store: Self.history(maximum))
        #expect(usual.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which")
    func limitPastItsRange() async {
        let maximum = ToolCatalog.listLimitRange.upperBound
        let store = Self.history(maximum + 10)
        let over = await Self.call(ToolCatalog.listName, ["limit": .int(maximum + 1)], store: store)
        #expect(
            over.text.hasPrefix(
                "limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nShowing 1–\(maximum) of \(maximum + 10) calls."))
        #expect(Self.ids(in: over.text) == Array(1...maximum))

        let under = await Self.call(ToolCatalog.listName, ["limit": .int(0)], store: store)
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of "))
        #expect(Self.ids(in: under.text) == [1])
    }

    @Test("Each page starts where the last one ended, and the last says that is all")
    func pagesChain() async {
        let store = Self.history(7)
        let first = await Self.call(ToolCatalog.listName, ["limit": 3], store: store)
        #expect(first.text.hasPrefix("Showing 1–3 of 7 calls. Pass offset=3 for the next page.\n\n"))
        #expect(Self.ids(in: first.text) == [1, 2, 3])
        let second = await Self.call(ToolCatalog.listName, ["limit": 3, "offset": 3], store: store)
        #expect(second.text.hasPrefix("Showing 4–6 of 7 calls. Pass offset=6 for the next page.\n\n"))
        #expect(Self.ids(in: second.text) == [4, 5, 6])
        let last = await Self.call(ToolCatalog.listName, ["limit": 3, "offset": 6], store: store)
        #expect(last.text.hasPrefix("Showing 7–7 of 7 calls. That is all.\n\n"))
        #expect(Self.ids(in: last.text) == [7])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero")
    func offsetEdges() async {
        let store = Self.history(7)
        let past = await Self.call(ToolCatalog.listName, ["offset": 7], store: store)
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 calls: offset=7 is past the end. That is all.\n\n"))
        #expect(Self.ids(in: past.text).isEmpty)

        let lastRow = await Self.call(ToolCatalog.listName, ["offset": 6], store: store)
        #expect(Self.ids(in: lastRow.text) == [7])

        let negative = await Self.call(ToolCatalog.listName, ["offset": -1], store: store)
        let range = ToolCatalog.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(Self.ids(in: negative.text) == Array(1...7))

        let beyond = await Self.call(
            ToolCatalog.listName, ["offset": .int(range.upperBound + 1)], store: store)
        #expect(beyond.text.hasPrefix("offset=\(range.upperBound + 1) is outside "))
    }

    @Test("Nothing matching is said plainly and carries no page notice")
    func emptyHistory() async {
        let result = await Self.call(ToolCatalog.listName, store: Self.history(0))
        #expect(result.text.contains("Nothing matched"))
        #expect(!result.text.contains("Showing"))
    }

    @Test("A listing states its order")
    func orderIsStated() async {
        let result = await Self.call(ToolCatalog.listName, store: Self.history(2))
        #expect(result.text.contains("newest first"))
    }

    @Test("The parties of a group call are clipped to a stated width, and only then is it said")
    func partiesAreClipped() async {
        let plain = await Self.call(ToolCatalog.listName, store: Self.history(3))
        #expect(!plain.text.contains("clipped"))

        let group = await Self.call(ToolCatalog.listName, store: Self.history(3, group: 40))
        let width = ToolCatalog.partiesWidth
        #expect(
            group.text.hasPrefix(
                "The other parties is clipped to \(width) characters in each row. Read one in full with call_get.\n\n"))
        for line in group.text.split(separator: "\n") where line.contains(" · id ") {
            let parties = line.components(separatedBy: " · ")[4]
            #expect(parties.count <= width)
        }
    }

    @Test("A default page of the widest rows, parties clipped at their width, is about one usual page")
    func defaultPageOfClippedRows() async {
        let result = await Self.call(
            ToolCatalog.listName,
            store: Self.history(ToolCatalog.defaultListLimit, group: 40))
        #expect(Self.ids(in: result.text).count == ToolCatalog.defaultListLimit)
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
        let maximum = ToolCatalog.listLimitRange.upperBound
        let full = await Self.call(
            ToolCatalog.listName, ["limit": .int(maximum)], store: Self.history(maximum, group: 40))
        #expect(full.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("A contact name far wider than any ordinary one is clipped with the rest, so the page stays whole")
    func wideNamesAreClipped() async {
        let contacts = FakeContactResolver()
        contacts.contacts = [(name: String(repeating: "n", count: 600), addresses: [Self.number])]
        let result = await Self.call(
            ToolCatalog.listName, ["limit": 100], store: Self.history(100), contacts: contacts)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(Self.ids(in: result.text).count == 100)
        #expect(result.text.hasPrefix("The other parties is clipped"))
    }

    // MARK: call_get participants

    @Test("The participants of a group call come a page at a time, in the order stored")
    func participantsPage() async {
        let store = Self.history(1, group: 7)
        let first = await Self.call(
            ToolCatalog.getName, ["call_id": 1, "limit": 3], store: store)
        #expect(first.text.hasPrefix("Showing 1–3 of 7 participants. Pass offset=3 for the next page.\n\n"))
        #expect(first.text.contains("ane1@example.com"))
        #expect(!first.text.contains("ane3@example.com"))
        let last = await Self.call(
            ToolCatalog.getName, ["call_id": 1, "limit": 3, "offset": 6], store: store)
        #expect(last.text.hasPrefix("Showing 7–7 of 7 participants. That is all.\n\n"))
        #expect(last.text.contains("ane6@example.com"))
        let past = await Self.call(
            ToolCatalog.getName, ["call_id": 1, "offset": 9], store: store)
        #expect(past.text.hasPrefix("Showing 0 of 7 participants: offset=9 is past the end. That is all.\n\n"))
    }

    @Test("A call whose participants all fit carries no notice, and limit is moved into its range")
    func participantsWhole() async {
        let store = Self.history(1, group: 4)
        let whole = await Self.call(ToolCatalog.getName, ["call_id": 1], store: store)
        #expect(!whole.text.contains("Showing"))
        #expect(whole.text.contains("ane3@example.com"))

        let maximum = ToolCatalog.participantLimitRange.upperBound
        let over = await Self.call(
            ToolCatalog.getName, ["call_id": 1, "limit": .int(maximum + 1)], store: store)
        #expect(over.text.hasPrefix("limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\n\n"))
    }

    @Test("A full page of participants fits a result, and wide addresses shrink the page")
    func participantsFit() async throws {
        let maximum = ToolCatalog.participantLimitRange.upperBound
        let full = await Self.call(
            ToolCatalog.getName, ["call_id": 1, "limit": .int(maximum)],
            store: Self.history(1, group: maximum + 20))
        #expect(full.text.utf16.count <= ToolStandard.longestResult)

        let store = FakeCallStore()
        let wide = String(repeating: "w", count: 1_000)
        store.callsValue = [
            Fixtures.call(
                id: 1, at: Fixtures.date(2026, 8, 12), with: (0..<100).map { "p\($0)-\(wide)@example.com" })
        ]
        let result = await Self.call(
            ToolCatalog.getName, ["call_id": 1, "limit": 100], store: store)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        let shown = (0..<100).filter { result.text.contains("p\($0)-w") }
        #expect(shown.count < 100 && shown.first == 0)
        #expect(result.text.hasPrefix("Showing 1–\(shown.count) of 100 participants. Pass offset=\(shown.count) for the next page.\n\n"))
    }

    // MARK: Arguments

    @Test("An argument the schema does not list is refused with the names allowed, and the old names fail")
    func unknownArguments() async {
        let store = Self.history(3)
        let old = await Self.call(
            ToolCatalog.listName, ["from": "2026-08-12"], store: store)
        #expect(old.isError)
        #expect(old.text.hasPrefix("Unknown argument 'from'. This tool takes: contact, direction, from_date, kind, limit, number, offset, to_date."))
        let status = await Self.call(ToolCatalog.statusName, ["limit": 1], store: store)
        #expect(status.isError)
        #expect(status.text.contains("takes no arguments"))
        let get = await Self.call(ToolCatalog.getName, ["call_id": 1, "to": 1], store: store)
        #expect(get.text.contains("Unknown argument 'to'"))
    }

    @Test("An unknown name is echoed only up to a short width")
    func unknownNameIsClipped() async {
        let long = String(repeating: "x", count: 5_000)
        let result = await Self.call(ToolCatalog.listName, [long: 1], store: Self.history(1))
        #expect(result.text.utf16.count < 300)
        let tool = await Self.call(long, store: Self.history(1))
        #expect(tool.text.utf16.count < 200)
        let date = await Self.call(
            ToolCatalog.listName, ["from_date": .string(long)], store: Self.history(1))
        #expect(date.isError && date.text.utf16.count < 800)
    }

    @Test("A value of the wrong type is refused with the form expected")
    func wrongTypes() async {
        let store = Self.history(3)
        for (name, value, expected) in [
            ("limit", Value.string("5"), "a whole number was expected"),
            ("offset", .double(1.5), "a whole number was expected"),
            ("limit", .bool(true), "a whole number was expected"),
            ("from_date", .int(3), "text was expected"),
            ("direction", .int(1), "text was expected"),
            ("number", .bool(false), "text was expected"),
            ("contact", .array([]), "text was expected"),
        ] {
            let result = await Self.call(ToolCatalog.listName, [name: value], store: store)
            #expect(result.isError, "\(name)")
            #expect(result.text.contains(expected), "\(name): \(result.text)")
        }
        let id = await Self.call(ToolCatalog.getName, ["call_id": "1"], store: store)
        #expect(id.isError && id.text.contains("a whole number was expected"))
    }

    @Test("A call id outside its range is refused, never moved")
    func identifierRange() async {
        let store = Self.history(3)
        let range = ToolCatalog.callIDRange
        for id in [range.lowerBound - 1, -5] {
            let result = await Self.call(ToolCatalog.getName, ["call_id": .int(id)], store: store)
            #expect(result.isError)
            #expect(result.text.contains("from \(range.lowerBound) to \(range.upperBound)"))
        }
        let beyond = await Self.call(
            ToolCatalog.getName, ["call_id": .int(range.upperBound)], store: store)
        #expect(beyond.text.contains("No call exists with id \(range.upperBound)"))
        let missing = await Self.call(ToolCatalog.getName, [:], store: store)
        #expect(missing.text.contains("Missing required argument 'call_id'"))
    }

    // MARK: Dates

    @Test("to_date is inclusive at the precision written")
    func inclusiveEnd() async {
        let store = Self.history(0)
        func filter(_ to: String) async -> Date? {
            _ = await Self.call(ToolCatalog.listName, ["to_date": .string(to)], store: store)
            return store.lastFilter?.to
        }
        #expect(await filter("2026-08-12") == Fixtures.date(2026, 8, 13, 0, 0))
        #expect(await filter("2026-08-12T09:00") == Fixtures.date(2026, 8, 12, 9, 1))
        #expect(await filter("2026-08-12T09:00:30") == Fixtures.date(2026, 8, 12, 9, 0).addingTimeInterval(31))
        #expect(await filter("2026-08-12T09:00:00+02:00") == Fixtures.date(2026, 8, 12, 9, 0).addingTimeInterval(1))
        _ = await Self.call(ToolCatalog.listName, ["from_date": "2026-08-12"], store: store)
        #expect(store.lastFilter?.from == Fixtures.date(2026, 8, 12, 0, 0))
    }

    @Test("A day that ends the range at its own start is one whole day, not an empty range")
    func sameDayRange() async {
        let result = await Self.call(
            ToolCatalog.listName,
            ["from_date": "2026-08-12T09:00", "to_date": "2026-08-12T09:00"], store: Self.history(0))
        #expect(!result.isError)
    }

    @Test("A date that does not exist is refused")
    func impossibleDates() async {
        for text in [
            "2026-02-30", "2026-02-29", "2026-04-31", "2026-02-30T09:00",
            // 02:30 does not exist in Madrid on 29 March 2026: the clocks go from 02:00 to 03:00.
            "2026-03-29T02:30", "2026-02-30T09:00:00+02:00",
        ] {
            let result = await Self.call(
                ToolCatalog.listName, ["from_date": .string(text)], store: Self.history(1))
            #expect(result.isError, "\(text)")
            #expect(result.text.contains("not a date this server accepts"), "\(text)")
        }
        let leap = await Self.call(
            ToolCatalog.listName, ["from_date": "2028-02-29"], store: Self.history(1))
        #expect(!leap.isError)
    }

    // MARK: Time

    private final class HangingStore: CallStore, @unchecked Sendable {
        func access() -> DatabaseAccess { .granted }
        func status() async throws -> StoreStatus { throw ToolError.storeFailure("unused") }
        func calls(_ filter: CallFilter, limit: Int, offset: Int) async throws -> CallPage {
            try await Task.sleep(for: .seconds(60))
            return CallPage(calls: [], total: 0)
        }
        func call(id: Int64) async throws -> CallRecord? {
            try await Task.sleep(for: .seconds(60))
            return nil
        }
    }

    @Test("A call that does not finish in time is answered with an error that says so")
    func deadline() async {
        let tools = PhoneTools(
            store: HangingStore(), contacts: FakeContactResolver(), calendar: Fixtures.calendar,
            timeout: .milliseconds(100))
        for (name, arguments) in [
            (ToolCatalog.listName, [String: Value]()), (ToolCatalog.getName, ["call_id": 1]),
        ] {
            let result = await tools.handle(.init(name: name, arguments: arguments))
            guard case .text(let text) = result.content.first else {
                Issue.record("no text")
                continue
            }
            #expect(result.isError)
            #expect(text.contains("did not finish within 0 seconds"))
            #expect(text.contains("nothing was changed"))
            #expect(text.contains("from_date and to_date"))
        }
    }

    @Test("The deadline is inside the time limit a call may take")
    func deadlineIsInsideTheLimit() {
        #expect(PhoneTools.defaultTimeout < ToolStandard.timeLimit)
    }

    // MARK: The texts the model reads

    @Test("No instructions or description is longer than a client reads")
    func textsFit() {
        #expect(
            ToolStandard.overlongTexts(
                instructions: PhoneMCPServer.instructions, catalog: ToolCatalog.all()
            ).isEmpty)
    }

    @Test("What is advertised is what the code enforces")
    func advertisedBoundsMatchTheCode() throws {
        let list = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.listName })
        let get = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.getName })
        func property(_ tool: Tool, _ name: String) -> [String: Value] {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"],
                case .object(let definition)? = properties[name]
            else { return [:] }
            return definition
        }
        let limit = property(list, "limit")
        #expect(limit["minimum"]?.intValue == ToolCatalog.listLimitRange.lowerBound)
        #expect(limit["maximum"]?.intValue == ToolCatalog.listLimitRange.upperBound)
        #expect(limit["default"]?.intValue == ToolCatalog.defaultListLimit)
        #expect(property(list, "offset")["maximum"]?.intValue == ToolCatalog.offsetRange.upperBound)
        let participants = property(get, "limit")
        #expect(participants["maximum"]?.intValue == ToolCatalog.participantLimitRange.upperBound)
        #expect(participants["default"]?.intValue == ToolCatalog.defaultParticipantLimit)
        #expect(property(get, "call_id")["maximum"]?.intValue == ToolCatalog.callIDRange.upperBound)

        let descriptions = (list.description ?? "") + (get.description ?? "") + PhoneMCPServer.instructions
        for figure in [
            ToolCatalog.defaultListLimit, ToolCatalog.listLimitRange.upperBound,
            ToolCatalog.defaultParticipantLimit, ToolCatalog.participantLimitRange.upperBound,
            ToolCatalog.partiesWidth,
        ] {
            #expect(descriptions.contains("\(figure)"), "\(figure)")
        }
        #expect(PhoneMCPServer.instructions.contains("\(PhoneTools.defaultTimeout.components.seconds) seconds"))
    }

    @Test("Both listing names of the standard are used, and none of the old ones remain")
    func standardNames() {
        for name in ["from_date", "to_date", "limit", "offset"] {
            #expect(ToolCatalog.argumentNames(of: ToolCatalog.listName)?.contains(name) == true)
        }
        #expect(ToolCatalog.argumentNames(of: ToolCatalog.listName)?.contains("from") == false)
        #expect(ToolCatalog.argumentNames(of: ToolCatalog.listName)?.contains("to") == false)
    }
}
