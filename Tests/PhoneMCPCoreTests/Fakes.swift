import Foundation

@testable import PhoneMCPCore

/// An in-memory `CallStore`. Every tool test runs against this double; nothing here opens
/// a database.
final class FakeCallStore: CallStore, @unchecked Sendable {

    var accessValue: DatabaseAccess = .granted
    var callsValue: [CallRecord] = []

    /// Set to make the next call fail, so the error path is reachable.
    var failure: (any Error)?

    private(set) var lastFilter: CallFilter?

    func access() -> DatabaseAccess { accessValue }

    func status() async throws -> StoreStatus {
        if let failure { throw failure }
        guard accessValue.isUsable else {
            return StoreStatus(access: accessValue, databasePath: "/invented/CallHistory.storedata")
        }
        return StoreStatus(
            access: accessValue,
            databasePath: "/invented/CallHistory.storedata",
            callCount: callsValue.count,
            oldestCall: callsValue.map(\.date).min(),
            newestCall: callsValue.map(\.date).max(),
            walBytes: 4096)
    }

    /// Mirrors what the real store does with each filter, so the dispatcher's argument
    /// handling is checked against behaviour rather than against itself.
    func calls(_ filter: CallFilter, limit: Int, offset: Int) async throws -> CallPage {
        if let failure { throw failure }
        lastFilter = filter
        let matches = callsValue
            .filter { record in filter.from.map { record.date >= $0 } ?? true }
            .filter { record in filter.to.map { record.date < $0 } ?? true }
            .filter { record in filter.direction.map { record.direction == $0 } ?? true }
            .filter { record in filter.kind.map { record.kind == $0 } ?? true }
            .filter { record in
                guard let wanted = filter.addresses else { return true }
                return record.remoteAddresses.contains { AddressKey($0).map(wanted.contains) ?? false }
            }
            .sorted { $0.date > $1.date }
        return CallPage(calls: Array(matches.dropFirst(offset).prefix(limit)), total: matches.count)
    }

    func call(id: Int64) async throws -> CallRecord? {
        if let failure { throw failure }
        return callsValue.first { $0.id == id }
    }
}

/// An in-memory address book. `requestAccess` answers with `grantOnRequest` and records
/// that it was asked, so the tests can prove when the dialog would appear.
final class FakeContactResolver: ContactResolver, @unchecked Sendable {

    var authorizationValue: ContactsAuthorization = .authorized
    var grantOnRequest: ContactsAuthorization = .authorized
    var contacts: [(name: String, addresses: [String])] = []
    private(set) var requestCount = 0

    func authorization() -> ContactsAuthorization { authorizationValue }

    func requestAccess() async -> ContactsAuthorization {
        requestCount += 1
        authorizationValue = grantOnRequest
        return authorizationValue
    }

    func names(for addresses: [String]) async throws -> [AddressKey: String] {
        let wanted = Set(addresses.compactMap(AddressKey.init))
        var found: [AddressKey: String] = [:]
        for contact in contacts {
            for key in contact.addresses.compactMap(AddressKey.init) where wanted.contains(key) {
                if found[key] == nil { found[key] = contact.name }
            }
        }
        return found
    }

    func addresses(matching name: String) async throws -> [(name: String, addresses: [String])] {
        contacts.filter { $0.name.localizedCaseInsensitiveContains(name) }
    }
}

/// Invented calls and people. No number here belongs to anyone: they use the reserved fictional 555-01xx
/// block and `example.com`.
enum Fixtures {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func call(
        id: Int64, at date: Date, direction: CallDirection = .incoming, kind: CallKind = .phone,
        duration: TimeInterval = 60, with addresses: [String] = ["+12125550101"]
    ) -> CallRecord {
        CallRecord(
            id: id, uniqueID: "CALL-\(id)", date: date, duration: duration,
            direction: direction,
            answered: direction == .outgoing ? nil : direction == .incoming,
            kind: kind,
            serviceProvider: kind == .phone ? "com.apple.Telephony" : "com.apple.FaceTime",
            remoteAddresses: addresses, storedName: nil, countryCode: "es",
            disconnectedCause: nil)
    }

    static let ane = (name: "Ane Example", addresses: ["212 555 0101", "ane@example.com"])
    static let jon = (name: "Jon Example", addresses: ["+1 212 555 0102"])
}
