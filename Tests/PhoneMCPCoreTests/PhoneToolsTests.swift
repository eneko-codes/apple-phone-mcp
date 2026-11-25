import Foundation
import Testing

@testable import PhoneMCPCore

/// Drives the tool layer end to end against `FakeCallStore` and `FakeContactResolver`.
/// No test here opens the call history or the address book.
@Suite("Tool dispatch")
struct PhoneToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeCallStore = FakeCallStore(),
        contacts: FakeContactResolver = FakeContactResolver()
    ) async -> (text: String, isError: Bool) {
        let tools = PhoneTools(store: store, contacts: contacts, calendar: Fixtures.calendar)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError)
    }

    private func stocked() -> FakeCallStore {
        let store = FakeCallStore()
        store.callsValue = [
            Fixtures.call(id: 1, at: Fixtures.date(2026, 8, 10, 9, 0), with: ["+12125550101"]),
            Fixtures.call(
                id: 2, at: Fixtures.date(2026, 8, 11, 18, 30), direction: .missed, duration: 0,
                with: ["2125550102"]),
            Fixtures.call(
                id: 3, at: Fixtures.date(2026, 8, 12, 20, 15), direction: .outgoing,
                kind: .facetimeVideo, duration: 754, with: ["ane@example.com"]),
            Fixtures.call(
                id: 4, at: Fixtures.date(2026, 8, 12, 21, 0), direction: .outgoing,
                kind: .facetimeAudio, with: ["+12125550102", "+12125550103"]),
        ]
        return store
    }

    private func addressBook() -> FakeContactResolver {
        let contacts = FakeContactResolver()
        contacts.contacts = [Fixtures.ane, Fixtures.jon]
        return contacts
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union and
    /// hands the model a bare `{}` instead, so the whole catalogue is walked.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    @Test("Every tool is annotated read-only and closed-world")
    func everyToolReads() {
        for tool in ToolCatalog.all() {
            #expect(tool.annotations.readOnlyHint == true, "\(tool.name)")
            #expect(tool.annotations.destructiveHint == false, "\(tool.name)")
            #expect(tool.annotations.openWorldHint == false, "\(tool.name)")
        }
    }

    // MARK: Access

    @Test("phone_status answers when Full Disk Access is missing, and names the fix")
    func statusWorksWithoutAccess() async {
        let store = FakeCallStore()
        store.accessValue = .denied
        let (text, isError) = await call(ToolCatalog.statusName, store: store)
        #expect(!isError)
        #expect(text.contains("FULL DISK ACCESS"))
        #expect(text.contains("binary"))
    }

    @Test("Reads are refused without Full Disk Access")
    func readsNeedAccess() async {
        let store = stocked()
        store.accessValue = .denied
        for name in [ToolCatalog.listName, ToolCatalog.getName] {
            let (text, isError) = await call(name, ["call_id": 1], store: store)
            #expect(isError, "\(name)")
            #expect(text.contains("Full Disk Access") || text.contains("FULL DISK ACCESS"))
        }
    }

    @Test("An unknown tool is refused")
    func unknownTool() async {
        let (text, isError) = await call("delete_call")
        #expect(isError)
        #expect(text.contains("not a tool of this server"))
    }

    // MARK: calls_list

    @Test("Calls are listed newest first with names from Contacts")
    func listsNewestFirstWithNames() async {
        let (text, isError) = await call(
            ToolCatalog.listName, store: stocked(), contacts: addressBook())
        #expect(!isError)
        #expect(text.hasPrefix("4 calls"))
        let ids = text.split(separator: "\n").compactMap { line in
            line.split(separator: " ").last.flatMap { Int($0) }
        }
        #expect(ids == [4, 3, 2, 1])
        #expect(text.contains("Ane Example (+12125550101)"))
        #expect(text.contains("Ane Example (ane@example.com)"))
        #expect(text.contains("Jon Example (2125550102)"))
        #expect(text.contains("+12125550103 · id 4"))
        #expect(text.contains("12m 34s"))
    }

    @Test("Without Contacts access every call is still listed, with numbers alone")
    func listsWithoutContacts() async {
        let contacts = addressBook()
        contacts.authorizationValue = .denied
        let (text, isError) = await call(ToolCatalog.listName, store: stocked(), contacts: contacts)
        #expect(!isError)
        #expect(text.hasPrefix("4 calls"))
        #expect(!text.contains("Ane Example"))
        #expect(contacts.requestCount == 0)
    }

    @Test("Contacts is asked for once when undecided, and its answer is used")
    func asksForContactsWhenUndecided() async {
        let contacts = addressBook()
        contacts.authorizationValue = .notDetermined
        let (text, _) = await call(ToolCatalog.listName, store: stocked(), contacts: contacts)
        #expect(contacts.requestCount == 1)
        #expect(text.contains("Ane Example"))
    }

    @Test("direction, kind and a date range combine with AND")
    func filtersCombine() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.listName,
            ["direction": "outgoing", "kind": "facetime_video", "from": "2026-08-12", "to": "2026-08-12"],
            store: store)
        #expect(!isError)
        #expect(text.hasPrefix("1 call ·"))
        #expect(text.contains("id 3"))
        // A plain-day 'to' covers that whole day.
        #expect(store.lastFilter?.to == Fixtures.date(2026, 8, 13, 0, 0))
    }

    @Test("A number matches however it was stored, with or without country code")
    func numberFilterIgnoresFormatting() async {
        let (text, _) = await call(
            ToolCatalog.listName, ["number": "+1 212 555 01 02"], store: stocked())
        #expect(text.hasPrefix("2 calls"))
        #expect(text.contains("id 2"))
        #expect(text.contains("id 4"))
    }

    @Test("A contact filter searches every number and email of the matching contacts")
    func contactFilter() async {
        let (text, isError) = await call(
            ToolCatalog.listName, ["contact": "Ane"], store: stocked(), contacts: addressBook())
        #expect(!isError)
        #expect(text.hasPrefix("2 calls"))
        #expect(text.contains("contact Ane Example"))
    }

    @Test("A contact filter is refused, not ignored, without Contacts access")
    func contactFilterNeedsContacts() async {
        let contacts = addressBook()
        contacts.authorizationValue = .denied
        let (text, isError) = await call(
            ToolCatalog.listName, ["contact": "Ane"], store: stocked(), contacts: contacts)
        #expect(isError)
        #expect(text.contains("needs access to Contacts"))
    }

    @Test("A contact nobody matches is an error, not an empty history")
    func unknownContact() async {
        let (text, isError) = await call(
            ToolCatalog.listName, ["contact": "Nobody"], store: stocked(), contacts: addressBook())
        #expect(isError)
        #expect(text.contains("No contact's name matches"))
    }

    @Test("A misspelt choice is refused rather than widening the filter")
    func badChoice() async {
        let (text, isError) = await call(ToolCatalog.listName, ["direction": "inbound"])
        #expect(isError)
        #expect(text.contains("expected one of"))
    }

    @Test("A range that ends before it starts is refused")
    func endBeforeStart() async {
        let (text, isError) = await call(
            ToolCatalog.listName, ["from": "2026-08-12", "to": "2026-08-01"])
        #expect(isError)
        #expect(text.contains("before 'from'"))
    }

    @Test("Paging says where the next page starts")
    func paging() async {
        let (text, _) = await call(ToolCatalog.listName, ["limit": 2], store: stocked())
        #expect(text.contains("showing 1–2"))
        #expect(text.contains("offset=2"))
        let (last, _) = await call(
            ToolCatalog.listName, ["limit": 2, "offset": 2], store: stocked())
        #expect(last.contains("showing 3–4"))
        #expect(!last.contains("offset="))
    }

    // MARK: call_get

    @Test("call_get never claims an outgoing call went unanswered")
    func outgoingAnsweredIsNotReported() async {
        let (text, isError) = await call(ToolCatalog.getName, ["call_id": 3], store: stocked())
        #expect(!isError)
        #expect(text.contains("not recorded for outgoing calls"))
        #expect(text.contains("FaceTime video"))
    }

    @Test("call_get lists every participant of a group call")
    func groupParticipants() async {
        let (text, _) = await call(
            ToolCatalog.getName, ["call_id": "4"], store: stocked(), contacts: addressBook())
        #expect(text.contains("Jon Example (+12125550102)"))
        #expect(text.contains("+12125550103"))
    }

    @Test("An unknown id is reported as such")
    func unknownID() async {
        let (text, isError) = await call(ToolCatalog.getName, ["call_id": 999], store: stocked())
        #expect(isError)
        #expect(text.contains("No call exists with id 999"))
    }

    @Test("A store failure becomes an error result, not a crash")
    func storeFailure() async {
        let store = stocked()
        store.failure = ToolError.storeFailure("disk I/O error")
        let (text, isError) = await call(ToolCatalog.listName, store: store)
        #expect(isError)
        #expect(text.contains("disk I/O error"))
    }
}
