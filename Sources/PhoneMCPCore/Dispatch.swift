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

    public init(
        store: any CallStore, contacts: any ContactResolver, calendar: Calendar = .current
    ) {
        self.store = store
        self.contacts = contacts
        self.calendar = calendar
        self.format = Format(calendar: calendar)
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        do {
            return ToolOutput(text: try await run(parameters), isError: false)
        } catch let error as ToolError {
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(text: error.message, isError: true)
        } catch {
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(
                text: ToolError.storeFailure(error.localizedDescription).message, isError: true)
        }
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

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

        case ToolCatalog.getName:
            let id = try arguments.requiredID("call_id")
            guard let record = try await store.call(id: id) else {
                throw ToolError.callNotFound(id: id)
            }
            return format.call(record, names: await names(for: [record]))

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    private func list(_ arguments: Arguments) async throws -> String {
        var filter = CallFilter()
        filter.from = try arguments.optionalDate("from")
        filter.to = try arguments.optionalDate("to", endOfDayIfDayOnly: true)
        if let from = filter.from, let to = filter.to, to < from {
            throw ToolError.endBeforeStart
        }
        filter.direction = try arguments.optionalChoice(
            "direction", from: ToolCatalog.directionChoices
        ).flatMap(CallDirection.init(rawValue:))
        filter.kind = try arguments.optionalChoice("kind", from: ToolCatalog.kindChoices)
            .flatMap { label in CallKind.filterable.first { $0.label == label } }

        var described: [String] = []
        if let number = arguments.optionalString("number") {
            guard let key = AddressKey(number) else {
                throw ToolError.badArgument(
                    name: "number", reason: "it has no digits and is not an email")
            }
            filter.addresses = [key]
            described.append("number \(number)")
        }
        if let name = arguments.optionalString("contact") {
            let (keys, matched) = try await addresses(forContact: name)
            // Combined with AND, like every other filter: number and contact together
            // narrow to that contact's calls from that number.
            filter.addresses = filter.addresses.map { $0.intersection(keys) } ?? keys
            described.append("contact \(matched.joined(separator: ", "))")
        }

        let limit = try arguments.int(
            "limit", default: Configuration.listLimit, in: Configuration.listLimitRange)
        let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        let page = try await store.calls(filter, limit: limit, offset: offset)
        return format.calls(
            page, names: await names(for: page.calls), filter: filter, described: described,
            offset: offset)
    }

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
        var authorization = contacts.authorization()
        if authorization == .notDetermined { authorization = await contacts.requestAccess() }
        guard authorization.isUsable else { return [:] }
        return (try? await contacts.names(for: records.flatMap(\.remoteAddresses))) ?? [:]
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
