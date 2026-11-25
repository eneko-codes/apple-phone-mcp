import Foundation
import SQLite3
import Testing

@testable import PhoneMCPCore

/// Exercises `SystemCallStore` — the one type that speaks SQL — against a database this
/// suite builds itself in a temporary directory.
///
/// The tables reproduce the schema read from a real `CallHistory.storedata` on macOS 27
/// (column names and types only). Every number, date and name below is invented. The
/// owner's real history is never opened, never copied and never read by this suite.
private final class Fixture {
    let directory: URL
    /// The writer stays open for the fixture's lifetime with automatic checkpoints off,
    /// the way `callservicesd` keeps the real file: rows it writes after
    /// `checkpoint()` live only in the `-wal` file until it closes.
    private let writer: OpaquePointer

    var path: String { directory.appendingPathComponent("CallHistory.storedata").path }

    /// Seconds since 2001-01-01, the Core Data reference date `ZDATE` is stored in.
    static func referenceSeconds(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }

    init(omitting omitted: Set<String> = []) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-phone-mcp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var pointer: OpaquePointer?
        let path = directory.appendingPathComponent("CallHistory.storedata").path
        guard sqlite3_open(path, &pointer) == SQLITE_OK, let pointer else {
            throw FixtureError.sqlite("open")
        }
        writer = pointer

        let recordColumns = [
            ("Z_PK", "INTEGER PRIMARY KEY"), ("Z_ENT", "INTEGER"), ("Z_OPT", "INTEGER"),
            ("ZANSWERED", "INTEGER"), ("ZCALLTYPE", "INTEGER"),
            ("ZDISCONNECTED_CAUSE", "INTEGER"), ("ZFACE_TIME_DATA", "INTEGER"),
            ("ZHANDLE_TYPE", "INTEGER"), ("ZORIGINATED", "INTEGER"), ("ZREAD", "INTEGER"),
            ("ZDATE", "TIMESTAMP"), ("ZDURATION", "FLOAT"), ("ZADDRESS", "VARCHAR"),
            ("ZISO_COUNTRY_CODE", "VARCHAR"), ("ZNAME", "VARCHAR"),
            ("ZORIGINATINGDEVICENAME", "VARCHAR"), ("ZSERVICE_PROVIDER", "VARCHAR"),
            ("ZUNIQUE_ID", "VARCHAR"),
        ].filter { !omitted.contains($0.0) }

        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA wal_autocheckpoint = 0")
        try execute(
            "CREATE TABLE ZCALLRECORD ("
                + recordColumns.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + ")")
        try execute(
            "CREATE TABLE ZHANDLE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, "
                + "ZTYPE INTEGER, ZNORMALIZEDVALUE VARCHAR, ZVALUE VARCHAR)")
        try execute(
            "CREATE TABLE Z_2REMOTEPARTICIPANTHANDLES (Z_2REMOTEPARTICIPANTCALLS INTEGER, "
                + "Z_4REMOTEPARTICIPANTHANDLES INTEGER, PRIMARY KEY (Z_2REMOTEPARTICIPANTCALLS, "
                + "Z_4REMOTEPARTICIPANTHANDLES))")
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(writer, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw FixtureError.sqlite(detail)
        }
    }

    /// Closes the writer and removes the sidecars, leaving a self-contained database.
    /// SQLite checkpoints when its last connection closes, so nothing is lost; the system
    /// library keeps the files afterwards (it persists the WAL), so they are deleted here
    /// to reproduce a database nobody has open.
    func closeWriterAndRemoveSidecars() {
        sqlite3_close(writer)
        closed = true
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    private var closed = false

    /// Moves everything written so far into the main file and empties the log.
    func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func insertCall(
        id: Int, at date: Date, originated: Int, answered: Int, type: Int = 1,
        duration: Double = 60, address: String? = "+12125550101",
        provider: String = "com.apple.Telephony"
    ) throws {
        let addressSQL = address.map { "'\($0)'" } ?? "NULL"
        try execute(
            """
            INSERT INTO ZCALLRECORD (Z_PK, ZDATE, ZDURATION, ZORIGINATED, ZANSWERED, ZCALLTYPE,
                                     ZADDRESS, ZSERVICE_PROVIDER, ZUNIQUE_ID)
            VALUES (\(id), \(Self.referenceSeconds(date)), \(duration), \(originated),
                    \(answered), \(type), \(addressSQL), '\(provider)', 'UNIQUE-\(id)')
            """)
    }

    func insertParticipant(call: Int, handle: Int, value: String) throws {
        try execute("INSERT OR IGNORE INTO ZHANDLE (Z_PK, ZVALUE) VALUES (\(handle), '\(value)')")
        try execute(
            "INSERT INTO Z_2REMOTEPARTICIPANTHANDLES VALUES (\(call), \(handle))")
    }

    deinit {
        if !closed { sqlite3_close(writer) }
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum FixtureError: Error {
    case sqlite(String)
}

@Suite("Call history database")
struct FixtureDatabaseTests {

    /// Two calls checkpointed into the main file, two more left only in the WAL.
    private func populated() throws -> Fixture {
        let fixture = try Fixture()
        try fixture.insertCall(
            id: 1, at: Fixtures.date(2026, 8, 10, 9, 0), originated: 0, answered: 1)
        try fixture.insertCall(
            id: 2, at: Fixtures.date(2026, 8, 11, 18, 30), originated: 0, answered: 0,
            duration: 0, address: "2125550102")
        try fixture.checkpoint()
        try fixture.insertCall(
            id: 3, at: Fixtures.date(2026, 8, 12, 20, 15), originated: 1, answered: 0, type: 8,
            duration: 754.6, address: "ane@example.com", provider: "com.apple.FaceTime")
        try fixture.insertCall(
            id: 4, at: Fixtures.date(2026, 8, 12, 21, 0), originated: 1, answered: 0, type: 16,
            address: "+12125550102", provider: "com.apple.FaceTime")
        try fixture.insertParticipant(call: 4, handle: 10, value: "+12125550102")
        try fixture.insertParticipant(call: 4, handle: 11, value: "+12125550103")
        return fixture
    }

    @Test("Calls still in the write-ahead log are read")
    func readsThroughTheWAL() async throws {
        let fixture = try populated()
        let walSize =
            (try FileManager.default.attributesOfItem(atPath: fixture.path + "-wal")[.size]
            as? NSNumber)?.intValue ?? 0
        #expect(walSize > 0, "the fixture should be holding rows in its WAL")

        let page = try await SystemCallStore(databasePath: fixture.path)
            .calls(CallFilter(), limit: 50, offset: 0)
        #expect(page.total == 4)
        #expect(page.calls.map(\.id) == [4, 3, 2, 1])
    }

    @Test("A database nobody has open any more is still read, and nothing is created beside it")
    func readsAfterTheWriterQuits() async throws {
        let fixture = try populated()
        fixture.closeWriterAndRemoveSidecars()

        let page = try await SystemCallStore(databasePath: fixture.path)
            .calls(CallFilter(), limit: 50, offset: 0)
        #expect(page.total == 4)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "-shm"))
    }

    @Test("Columns decode into direction, kind, duration and date")
    func decodesColumns() async throws {
        let fixture = try populated()
        let store = SystemCallStore(databasePath: fixture.path)
        let calls = try await store.calls(CallFilter(), limit: 50, offset: 0).calls
        let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) })

        #expect(byID[1]?.direction == .incoming)
        #expect(byID[1]?.answered == true)
        #expect(byID[1]?.date == Fixtures.date(2026, 8, 10, 9, 0))
        #expect(byID[2]?.direction == .missed)
        #expect(byID[2]?.answered == false)
        #expect(byID[3]?.direction == .outgoing)
        #expect(byID[3]?.answered == nil)
        #expect(byID[3]?.kind == .facetimeVideo)
        #expect(byID[3]?.duration == 754.6)
        #expect(byID[3]?.serviceProvider == "com.apple.FaceTime")
        #expect(byID[4]?.kind == .facetimeAudio)
        // The stored address and the participant handle are the same number, listed once.
        #expect(byID[4]?.remoteAddresses == ["+12125550102", "+12125550103"])
    }

    @Test("Filters are applied in SQL and in the address match")
    func filters() async throws {
        let fixture = try populated()
        let store = SystemCallStore(databasePath: fixture.path)

        var missed = CallFilter()
        missed.direction = .missed
        #expect(try await store.calls(missed, limit: 50, offset: 0).calls.map(\.id) == [2])

        var range = CallFilter()
        range.from = Fixtures.date(2026, 8, 11)
        range.to = Fixtures.date(2026, 8, 12, 21, 0)
        #expect(try await store.calls(range, limit: 50, offset: 0).calls.map(\.id) == [3, 2])

        var number = CallFilter()
        number.addresses = [AddressKey("+1 212 555 0102")!]
        let page = try await store.calls(number, limit: 1, offset: 0)
        #expect(page.total == 2)
        #expect(page.calls.map(\.id) == [4])
    }

    @Test("The database pages at the source: a page, the total, and no tie between two calls")
    func pagesAtTheSource() async throws {
        let fixture = try Fixture()
        // Ten calls of the very same instant: only the id can order them.
        for id in 1...10 {
            try fixture.insertCall(id: id, at: Fixtures.date(2026, 8, 10, 9, 0), originated: 1, answered: 0)
        }
        let store = SystemCallStore(databasePath: fixture.path)
        var seen: [Int64] = []
        for offset in stride(from: 0, to: 10, by: 4) {
            let page = try await store.calls(CallFilter(), limit: 4, offset: offset)
            #expect(page.total == 10)
            seen += page.calls.map(\.id)
        }
        #expect(seen == Array((1...10).reversed()).map(Int64.init))
        #expect(try await store.calls(CallFilter(), limit: 4, offset: 10).calls.isEmpty)
        #expect(try await store.calls(CallFilter(), limit: 4, offset: 10).total == 10)
    }

    @Test("A page under an address filter holds only the page, and the total counts every match")
    func addressFilterPages() async throws {
        let fixture = try Fixture()
        for id in 1...9 {
            let address = id.isMultiple(of: 3) ? "+12125550199" : "+12125550101"
            try fixture.insertCall(
                id: id, at: Fixtures.date(2026, 8, 10, 9, id), originated: 0, answered: 1,
                address: address)
        }
        var filter = CallFilter()
        filter.addresses = [AddressKey("2125550101")!]
        let store = SystemCallStore(databasePath: fixture.path)
        let first = try await store.calls(filter, limit: 4, offset: 0)
        #expect(first.total == 6)
        #expect(first.calls.map(\.id) == [8, 7, 5, 4])
        let second = try await store.calls(filter, limit: 4, offset: 4)
        #expect(second.calls.map(\.id) == [2, 1])
        #expect(second.total == 6)
    }

    @Test("A filter by date pages in SQL with its own total")
    func dateFilterPages() async throws {
        let fixture = try Fixture()
        for id in 1...6 {
            try fixture.insertCall(id: id, at: Fixtures.date(2026, 8, id, 9, 0), originated: 0, answered: 1)
        }
        var filter = CallFilter()
        filter.from = Fixtures.date(2026, 8, 2, 0, 0)
        filter.to = Fixtures.date(2026, 8, 5, 0, 0)
        let page = try await SystemCallStore(databasePath: fixture.path)
            .calls(filter, limit: 2, offset: 1)
        #expect(page.total == 3)
        #expect(page.calls.map(\.id) == [3, 2])
    }

    @Test("The participants of a page are read for that page's calls alone")
    func participantsOfThePage() async throws {
        let fixture = try Fixture()
        for id in 1...3 {
            try fixture.insertCall(id: id, at: Fixtures.date(2026, 8, id, 9, 0), originated: 1, answered: 0)
            try fixture.insertParticipant(call: id, handle: 10 + id, value: "+121255501\(10 + id)")
        }
        let page = try await SystemCallStore(databasePath: fixture.path)
            .calls(CallFilter(), limit: 1, offset: 1)
        #expect(page.calls.map(\.remoteAddresses) == [["+12125550101", "+12125550112"]])
    }

    @Test("A cancelled call stops reading")
    func cancelledScanStops() async throws {
        let fixture = try Fixture()
        try fixture.insertCall(id: 1, at: Fixtures.date(2026, 8, 10, 9, 0), originated: 0, answered: 1)
        let store = SystemCallStore(databasePath: fixture.path)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.calls(CallFilter(), limit: 1, offset: 0)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("status counts every call and the span they cover")
    func status() async throws {
        let fixture = try populated()
        let status = try await SystemCallStore(databasePath: fixture.path).status()
        #expect(status.access == .granted)
        #expect(status.callCount == 4)
        #expect(status.oldestCall == Fixtures.date(2026, 8, 10, 9, 0))
        #expect(status.newestCall == Fixtures.date(2026, 8, 12, 21, 0))
        #expect(status.missingOptionalColumns.isEmpty)
        #expect((status.walBytes ?? 0) > 0)
    }

    @Test("call(id:) finds one call and answers nil for an unknown id")
    func singleCall() async throws {
        let fixture = try populated()
        let store = SystemCallStore(databasePath: fixture.path)
        #expect(try await store.call(id: 3)?.remoteAddresses == ["ane@example.com"])
        #expect(try await store.call(id: 999) == nil)
    }

    @Test("The handle this server opens refuses every write")
    func refusesWrites() throws {
        let fixture = try populated()
        let database = try CallHistoryDatabase(path: fixture.path)
        #expect(database.executeForTesting("UPDATE ZCALLRECORD SET ZDURATION = 0") != SQLITE_OK)
        #expect(database.executeForTesting("DELETE FROM ZCALLRECORD") != SQLITE_OK)
        #expect(database.executeForTesting("CREATE TABLE intruder (x)") != SQLITE_OK)
    }

    @Test("A missing load-bearing column is reported as a schema change, not an empty result")
    func missingRequiredColumn() async throws {
        let fixture = try Fixture(omitting: ["ZCALLTYPE"])
        await #expect(throws: ToolError.schemaUnsupported(table: "ZCALLRECORD", missing: ["ZCALLTYPE"])) {
            _ = try await SystemCallStore(databasePath: fixture.path)
                .calls(CallFilter(), limit: 50, offset: 0)
        }
    }

    @Test("A missing optional column degrades to NULL and is reported")
    func missingOptionalColumn() async throws {
        let fixture = try Fixture(omitting: ["ZDISCONNECTED_CAUSE", "ZNAME"])
        try fixture.insertCall(
            id: 1, at: Fixtures.date(2026, 8, 10, 9, 0), originated: 0, answered: 1)
        let store = SystemCallStore(databasePath: fixture.path)
        let record = try await store.call(id: 1)
        #expect(record?.disconnectedCause == nil)
        #expect(record?.direction == .incoming)
        #expect(try await store.status().missingOptionalColumns == ["ZNAME", "ZDISCONNECTED_CAUSE"])
    }

    @Test("A path with no database is reported missing, and nothing is created there")
    func missingFile() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-phone-mcp-absent-\(UUID().uuidString).storedata").path
        let store = SystemCallStore(databasePath: path)
        #expect(store.access() == .missing(path: path))
        await #expect(throws: ToolError.self) {
            _ = try await store.calls(CallFilter(), limit: 1, offset: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
