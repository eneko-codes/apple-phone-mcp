import Foundation

/// Routes a `tools/call` to the stores and renders the answer.
///
/// Never opens the call history and never touches Contacts directly — everything goes
/// through `CallStore` and `ContactResolver`, which is what lets the tests drive every
/// branch below against in-memory doubles with no Full Disk Access and no real data.
public struct PhoneTools: ToolHandler {
    private let store: any CallStore
    private let contacts: any ContactResolver
    private let calendar: Calendar
    private let format: Format

    /// Well under the 60 seconds a client commonly waits, and so under
    /// `ToolStandard.timeLimit`, so the answer is ours and not the client's generic "no
    /// result". The slowest honest call is a scan of the history plus a Contacts lookup.
    public static let defaultTimeout = Duration.seconds(30)

    private let timeout: Duration

    public init(
        store: any CallStore, contacts: any ContactResolver, calendar: Calendar = .current,
        timeout: Duration = PhoneTools.defaultTimeout
    ) {
        self.store = store
        self.contacts = contacts
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(seconds: Int(timeout.components.seconds)),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let message = (error as? ToolError)?.message
            ?? ToolError.storeFailure(error.localizedDescription).message
        return ToolOutput(text: message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        guard let allowed = ToolCatalog.argumentNames(of: parameters.name) else {
            throw ToolError.unknownTool(parameters.name)
        }
        let arguments = Arguments(parameters.arguments, calendar: calendar)
        try arguments.refuseUnknown(allowed: allowed)

        // Reported before the access check, because "what is wrong and how do I fix it"
        // is exactly the question asked when the database cannot be opened.
        if parameters.name == ToolCatalog.statusName {
            return format.status(
                try await store.status(), contacts: contacts.authorization(),
                binaryPath: Self.binaryPath)
        }

        let access = store.access()
        guard access.isUsable else { throw ToolError.notAuthorized(access) }

        switch parameters.name {
        case ToolCatalog.listName:
            return try await list(arguments)
        default:
            return try await get(arguments)
        }
    }

    private func get(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredID("call_id", in: ToolCatalog.callIDRange)
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultParticipantLimit,
            limits: ToolCatalog.participantLimitRange)
        guard let record = try await store.call(id: id) else {
            throw ToolError.callNotFound(id: id)
        }
        let shown = Array(record.remoteAddresses.dropFirst(page.offset).prefix(page.limit))
        let names = await names(forAddresses: shown)
        // Halved while the text is still too long, so a page of very wide addresses holds
        // fewer of them and says where to resume, and never reaches the guard to be cut.
        return ToolStandard.fitting(page.limit) { size in
            format.call(
                record, participants: Array(shown.prefix(size)), participantOffset: page.offset,
                participantTotal: record.remoteAddresses.count, names: names,
                notices: arguments.notices)
        }
    }

    private func list(_ arguments: Arguments) async throws -> String {
        var filter = CallFilter()
        var described: [String] = []

        let from = try arguments.optionalDate("from_date")
        let to = try arguments.optionalDate("to_date", inclusiveEnd: true)
        filter.from = from?.date
        filter.to = to?.date
        if let from, let to, to.date <= from.date {
            throw ToolError.endBeforeStart
        }
        if let from { described.append("from \(ToolStandard.echo(from.written))") }
        if let to { described.append("to \(ToolStandard.echo(to.written))") }

        filter.direction = try arguments.optionalChoice(
            "direction", from: ToolCatalog.directionChoices
        ).flatMap(CallDirection.init(rawValue:))
        filter.kind = try arguments.optionalChoice("kind", from: ToolCatalog.kindChoices)
            .flatMap { label in CallKind.filterable.first { $0.label == label } }
        if let direction = filter.direction { described.insert(direction.rawValue, at: 0) }
        if let kind = filter.kind { described.insert(Format.kind(kind), at: 0) }

        if let number = try arguments.optionalString("number") {
            guard let key = AddressKey(number) else {
                throw ToolError.badArgument(
                    name: "number", reason: "it has no digits and is not an email")
            }
            filter.addresses = [key]
            described.append("number \(ToolStandard.echo(number))")
        }
        if let name = try arguments.optionalString("contact") {
            let (keys, matched) = try await addresses(forContact: name)
            // Combined with AND, like every other filter: number and contact together
            // narrow to that contact's calls from that number.
            filter.addresses = filter.addresses.map { $0.intersection(keys) } ?? keys
            // A short name can match most of an address book, so only a few are named.
            let shownNames = matched.prefix(Self.namedContacts).map(ToolStandard.echo)
            let others = matched.count - shownNames.count
            described.append(
                "contact " + shownNames.joined(separator: ", ")
                    + (others > 0 ? " and \(others) more" : ""))
        }

        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultListLimit, limits: ToolCatalog.listLimitRange)

        // The store pages at the source: the rows of the page and the number of matches,
        // never every matching row.
        let found = try await store.calls(filter, limit: page.limit, offset: page.offset)
        let names = await names(for: found.calls)
        return ToolStandard.fitting(page.limit) { size in
            format.calls(
                Array(found.calls.prefix(size)), total: found.total, offset: page.offset,
                names: names, described: described, notices: arguments.notices)
        }
    }

    /// How many matching contacts the result names; the rest are counted.
    private static let namedContacts = 5

    private func addresses(forContact name: String) async throws -> (Set<AddressKey>, [String]) {
        var authorization = contacts.authorization()
        if authorization == .notDetermined { authorization = await contacts.requestAccess() }
        guard authorization.isUsable else { throw ToolError.contactsUnavailable(authorization) }

        let matches = try await contacts.addresses(matching: name)
        let keys = Set(matches.flatMap(\.addresses).compactMap(AddressKey.init))
        guard !keys.isEmpty else { throw ToolError.contactNotFound(name: name) }
        return (keys, matches.map(\.name))
    }

    /// Names are a courtesy, never a reason to fail: with Contacts denied, or an address
    /// book error, the calls are still shown, with numbers alone.
    private func names(for records: [CallRecord]) async -> [AddressKey: String] {
        await names(forAddresses: records.flatMap(\.remoteAddresses))
    }

    private func names(forAddresses addresses: [String]) async -> [AddressKey: String] {
        var authorization = contacts.authorization()
        if authorization == .notDetermined { authorization = await contacts.requestAccess() }
        guard authorization.isUsable else { return [:] }
        return (try? await contacts.names(for: addresses)) ?? [:]
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
