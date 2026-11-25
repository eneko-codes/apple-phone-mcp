import Foundation
import SQLite3

/// Read-only reader for a `CallHistory.storedata` database.
///
/// Takes a path, so the tests point it at a database they build themselves and the
/// owner's real history is never opened by the suite. `SystemCallStore` is the only thing
/// that hands it the real one.
///
/// ## Why it reads through the write-ahead log
///
/// The file is opened through a URI with `mode=ro`, and the flags exclude
/// `SQLITE_OPEN_READWRITE`, so SQLite refuses every write. It is deliberately **not**
/// opened `immutable=1`. `callservicesd` keeps this database in WAL mode and checkpoints
/// rarely — on the machine this was built on the `-wal` file was more than twice the size
/// of the main file — so an immutable reader, which never looks at the log, would miss
/// exactly the calls someone is most likely to ask about: the recent ones.
///
/// The cost of reading the log is a shared lock on the `-shm` index for the length of one
/// read transaction, and SQLite records the reader in that index — so the `-shm` file's
/// bytes and modification time change when this server reads. It is a coordination file,
/// never call data. In WAL mode a reader never blocks the writer, and a read-only
/// connection cannot checkpoint, so `callservicesd` keeps writing while this server reads.
/// Every read here is a single short transaction, opened and closed per tool call.
///
/// ## When there is no log to read
///
/// SQLite documents when a read-only connection can open a WAL database: the `-shm` and
/// `-wal` files exist and are readable, the directory is writable so they can be created,
/// or the file is opened `immutable` (https://www.sqlite.org/wal.html). A `mode=ro`
/// connection to a database whose sidecars are gone failed to open when tried, with
/// `SQLITE_CANTOPEN`. Sidecars are gone only when no connection has the database open —
/// the last one to close deletes them — and then nothing is changing the file, which is
/// exactly what `immutable=1` promises. So that, and only that, is when it is used.
///
/// ## Why every column is probed
///
/// This schema is Core Data's, private and undocumented. Apple adds columns between
/// releases, and the join table's column names embed entity numbers that a model change
/// would renumber. Selecting a column that does not exist fails the whole statement, so
/// the reader asks `PRAGMA table_info` first: the columns in `requiredColumns` are
/// load-bearing and their absence is reported as a bug in this server; the optional ones
/// degrade to `NULL`.
final class CallHistoryDatabase {

    /// `sqlite3_bind_text` must copy: the Swift string backing the pointer is gone by the
    /// time the statement runs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Application Support/CallHistoryDB/CallHistory.storedata")
    }

    private let handle: OpaquePointer
    let path: String

    /// Column names actually present, per table.
    private var presentColumns: [String: Set<String>] = [:]

    // MARK: Opening

    /// SQLite URI for a path, always read-only.
    ///
    /// Static and pure so the one string that decides whether this server can write is
    /// asserted directly in a test rather than inferred from behaviour.
    static func uri(forPath path: String, immutable: Bool = false) -> String {
        // Everything outside this set is percent-encoded. '?' would start the query
        // string, '#' the fragment and '%' an escape, so a path containing one of them
        // would otherwise open a different file — or a writable one.
        let unreserved = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/:@!$&'()*+,;=")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
        return "file:\(encoded)?mode=ro" + (immutable ? "&immutable=1" : "")
    }

    /// Whether a connection currently has this database open in WAL mode. The `-shm` file
    /// exists for exactly as long as one does.
    static func hasJournalSidecars(path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "-wal")
            && FileManager.default.fileExists(atPath: path + "-shm")
    }

    /// `mode=ro`, through the log, whenever another process has the file open; the
    /// documented `immutable=1` fallback only when it demonstrably has not.
    static func openingURI(forPath path: String) -> String {
        uri(forPath: path, immutable: !hasJournalSidecars(path: path))
    }

    /// Distinguishes "not there" from "not allowed" before SQLite is involved.
    ///
    /// SQLite reports both as `SQLITE_CANTOPEN`, and the two need completely different
    /// advice. `open(2)` is the only thing that knows which it is: Full Disk Access
    /// denial surfaces as EPERM, and a hidden parent directory as ENOENT. `O_NONBLOCK`
    /// keeps a FIFO planted at the path from hanging the probe.
    static func probeAccess(path: String) -> DatabaseAccess {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        return classify(errno: errno, path: path)
    }

    static func classify(errno code: Int32, path: String) -> DatabaseAccess {
        switch code {
        case EPERM, EACCES: return .denied
        case ENOENT, ENOTDIR: return .missing(path: path)
        default: return .failed(String(cString: strerror(code)))
        }
    }

    /// Apple's SQLite reports a sandbox or TCC refusal as `SQLITE_AUTH` rather than
    /// `SQLITE_CANTOPEN`, and sometimes only through the system errno.
    static func isPermissionDenied(code: Int32, systemErrno: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_AUTH || primary == SQLITE_PERM
            || systemErrno == EPERM || systemErrno == EACCES
    }

    init(path: String) throws {
        self.path = path

        var pointer: OpaquePointer?
        // No SQLITE_OPEN_READWRITE and no SQLITE_OPEN_CREATE: a typo in the path must
        // fail, never conjure an empty database next to the real one.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(Self.openingURI(forPath: path), &pointer, flags, nil)
        guard code == SQLITE_OK, let pointer else {
            let detail = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
            let systemErrno = pointer.map { sqlite3_system_errno($0) } ?? 0
            if pointer != nil { sqlite3_close(pointer) }
            if Self.isPermissionDenied(code: code, systemErrno: systemErrno) {
                throw ToolError.notAuthorized(.denied)
            }
            throw ToolError.notAuthorized(
                code & 0xFF == SQLITE_CANTOPEN ? Self.probeAccess(path: path) : .failed(detail))
        }
        self.handle = pointer
        // A second, independent refusal to write, in case a future edit ever widens the
        // open flags.
        try execute("PRAGMA query_only = ON")
    }

    deinit { sqlite3_close(handle) }

    // MARK: Transactions

    /// Runs `body` inside one read transaction, so a count and the page it describes are
    /// taken from the same snapshot even while `callservicesd` is writing.
    func read<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            _ = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw ToolError.storeFailure(String(cString: sqlite3_errmsg(handle)))
        }
    }

    // MARK: Schema

    static let recordTable = "ZCALLRECORD"
    static let handleTable = "ZHANDLE"
    static let participantTable = "Z_2REMOTEPARTICIPANTHANDLES"

    /// Columns this server cannot work without, per table. Everything else degrades to
    /// `NULL` and a slightly poorer answer.
    static let requiredColumns: [String: [String]] = [
        recordTable: [
            "Z_PK", "ZDATE", "ZDURATION", "ZORIGINATED", "ZANSWERED", "ZCALLTYPE",
            "ZADDRESS",
        ],
        handleTable: ["Z_PK", "ZVALUE"],
        participantTable: ["Z_2REMOTEPARTICIPANTCALLS", "Z_4REMOTEPARTICIPANTHANDLES"],
    ]

    /// Read when present, `NULL` when not.
    static let optionalColumns = [
        "ZUNIQUE_ID", "ZSERVICE_PROVIDER", "ZNAME", "ZISO_COUNTRY_CODE", "ZDISCONNECTED_CAUSE",
    ]

    func columns(of table: String) throws -> Set<String> {
        if let cached = presentColumns[table] { return cached }
        var names: Set<String> = []
        // Interpolated because PRAGMA does not accept a bound parameter. Every caller
        // passes one of the table constants above; nothing user-supplied reaches here.
        try query("PRAGMA table_info(\(table))") { statement in
            if let name = Self.text(statement, 1) { names.insert(name) }
        }
        presentColumns[table] = names
        return names
    }

    /// Throws the moment a load-bearing column is gone, so the failure names the schema
    /// change instead of surfacing as an empty history.
    func verifySchema() throws {
        for (table, required) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            let present = try columns(of: table)
            guard !present.isEmpty else {
                throw ToolError.schemaUnsupported(table: table, missing: required)
            }
            let missing = required.filter { !present.contains($0) }
            guard missing.isEmpty else {
                throw ToolError.schemaUnsupported(table: table, missing: missing)
            }
        }
    }

    func missingOptionalColumns() throws -> [String] {
        let present = try columns(of: Self.recordTable)
        return Self.optionalColumns.filter { !present.contains($0) }
    }

    /// `r.column`, or the literal `NULL` when this macOS does not have that column.
    ///
    /// Keeps the column indices in the row reader fixed whatever the schema is missing,
    /// which is what stops a schema change from silently shifting every field by one.
    private func selected(_ column: String) throws -> String {
        try columns(of: Self.recordTable).contains(column) ? "r.\(column)" : "NULL"
    }

    // MARK: Statement plumbing

    private func query(
        _ sql: String, bind: (OpaquePointer) throws -> Void = { _ in },
        row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw ToolError.storeFailure(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        try bind(statement)
        while true {
            // The deadline cancels the task; stop reading rather than finish a scan nobody
            // is waiting for.
            try Task.checkCancellation()
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            // An error mid-scan must not read as "that was every row".
            default: throw ToolError.storeFailure(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// Exposed for the test that proves this handle refuses writes. Nothing in the server
    /// calls it.
    func executeForTesting(_ sql: String) -> Int32 {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    fileprivate static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let raw = sqlite3_column_text(statement, index)
        else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    fileprivate static func integer(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    fileprivate static func double(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    // MARK: Reads

    func callCount() throws -> Int {
        var total = 0
        try query("SELECT COUNT(*) FROM \(Self.recordTable)") {
            total = Int(Self.integer($0, 0) ?? 0)
        }
        return total
    }

    /// `ZDATE` is seconds since 2001-01-01 — Core Data's reference date — so it converts
    /// with a cast, not an offset. Stored as REAL on most rows and INTEGER on a few; the
    /// column type is read per value.
    func dateRange() throws -> (oldest: Date?, newest: Date?) {
        var range: (Date?, Date?) = (nil, nil)
        try query("SELECT MIN(ZDATE), MAX(ZDATE) FROM \(Self.recordTable)") { statement in
            range = (
                Self.double(statement, 0).map(Date.init(timeIntervalSinceReferenceDate:)),
                Self.double(statement, 1).map(Date.init(timeIntervalSinceReferenceDate:))
            )
        }
        return range
    }

    /// The remote addresses of calls, per call id, from the participant join table, in the
    /// order the handles were stored. With `calls` the lookup is for those ids alone; with
    /// `nil` it reads the whole table, which only an address filter needs: it has to look
    /// at every call, and the table is a map of short strings, not of call rows.
    func participants(forCalls calls: [Int64]? = nil) throws -> [Int64: [String]] {
        var byCall: [Int64: [String]] = [:]
        if let calls, calls.isEmpty { return byCall }
        let restriction = calls.map {
            "WHERE j.Z_2REMOTEPARTICIPANTCALLS IN (\(Array(repeating: "?", count: $0.count).joined(separator: ",")))"
        } ?? ""
        try query(
            """
            SELECT j.Z_2REMOTEPARTICIPANTCALLS, h.ZVALUE
            FROM \(Self.participantTable) j
            JOIN \(Self.handleTable) h ON h.Z_PK = j.Z_4REMOTEPARTICIPANTHANDLES
            \(restriction)
            ORDER BY j.Z_2REMOTEPARTICIPANTCALLS, h.Z_PK
            """,
            bind: { statement in
                for (index, call) in (calls ?? []).enumerated() {
                    sqlite3_bind_int64(statement, Int32(index + 1), call)
                }
            }
        ) { statement in
            guard let call = Self.integer(statement, 0), let value = Self.text(statement, 1)
            else { return }
            byCall[call, default: []].append(value)
        }
        return byCall
    }

    /// One row of `ZCALLRECORD` as read, before its participants are known.
    private struct Row {
        let id: Int64
        let uniqueID: String?
        let date: Date
        let duration: Double
        let originated: Bool
        let answered: Bool
        let kind: CallKind
        let serviceProvider: String?
        let address: String?
        let storedName: String?
        let countryCode: String?
        let disconnectedCause: Int64?

        init?(_ statement: OpaquePointer) {
            guard let id = CallHistoryDatabase.integer(statement, 0) else { return nil }
            self.id = id
            uniqueID = CallHistoryDatabase.text(statement, 1)
            date = Date(
                timeIntervalSinceReferenceDate: CallHistoryDatabase.double(statement, 2) ?? 0)
            duration = CallHistoryDatabase.double(statement, 3) ?? 0
            originated = (CallHistoryDatabase.integer(statement, 4) ?? 0) == 1
            answered = (CallHistoryDatabase.integer(statement, 5) ?? 0) == 1
            kind = CallKind(rawValue: CallHistoryDatabase.integer(statement, 6) ?? 0)
            serviceProvider = CallHistoryDatabase.text(statement, 7)
            address = CallHistoryDatabase.text(statement, 8)
            storedName = CallHistoryDatabase.text(statement, 9)
            countryCode = CallHistoryDatabase.text(statement, 10)
            disconnectedCause = CallHistoryDatabase.integer(statement, 11)
        }

        func record(participants: [String]) -> CallRecord {
            var addresses = participants
            if let address, let key = AddressKey(address),
                !addresses.contains(where: { AddressKey($0) == key })
            {
                addresses.insert(address, at: 0)
            }
            return CallRecord(
                id: id, uniqueID: uniqueID, date: date, duration: duration,
                direction: .from(originated: originated, answered: answered),
                answered: originated ? nil : answered, kind: kind,
                serviceProvider: serviceProvider, remoteAddresses: addresses,
                storedName: storedName, countryCode: countryCode,
                disconnectedCause: disconnectedCause)
        }
    }

    private func selectColumns() throws -> String {
        """
        SELECT r.Z_PK, \(try selected("ZUNIQUE_ID")), r.ZDATE, r.ZDURATION,
               r.ZORIGINATED, r.ZANSWERED, r.ZCALLTYPE, \(try selected("ZSERVICE_PROVIDER")),
               r.ZADDRESS, \(try selected("ZNAME")), \(try selected("ZISO_COUNTRY_CODE")),
               \(try selected("ZDISCONNECTED_CAUSE"))
        FROM \(Self.recordTable) r
        """
    }

    /// The SQL-expressible part of `filter`, as a `WHERE` clause (or nothing) and the
    /// values to bind to it, in order.
    ///
    /// The address part of the filter is not here: an address needs the participant table
    /// and the same normalisation Contacts numbers get, and that is done in Swift.
    private func restriction(_ filter: CallFilter) -> (sql: String, binds: [(OpaquePointer, Int32) -> Void]) {
        var clauses: [String] = []
        var binds: [(OpaquePointer, Int32) -> Void] = []

        if let from = filter.from {
            clauses.append("r.ZDATE >= ?")
            let value = from.timeIntervalSinceReferenceDate
            binds.append { sqlite3_bind_double($0, $1, value) }
        }
        if let to = filter.to {
            clauses.append("r.ZDATE < ?")
            let value = to.timeIntervalSinceReferenceDate
            binds.append { sqlite3_bind_double($0, $1, value) }
        }
        if let kind = filter.kind {
            clauses.append("r.ZCALLTYPE = ?")
            let value = kind.rawValue
            binds.append { sqlite3_bind_int64($0, $1, value) }
        }
        // Literal predicates chosen from an enum; no caller text reaches the SQL.
        switch filter.direction {
        case .outgoing?: clauses.append("COALESCE(r.ZORIGINATED, 0) = 1")
        case .incoming?:
            clauses.append("COALESCE(r.ZORIGINATED, 0) = 0 AND COALESCE(r.ZANSWERED, 0) = 1")
        case .missed?:
            clauses.append("COALESCE(r.ZORIGINATED, 0) = 0 AND COALESCE(r.ZANSWERED, 0) = 0")
        case nil: break
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), binds)
    }

    /// Newest first, and `Z_PK` breaks a tie between two calls of the same instant, so no
    /// two rows ever tie and a second page starts exactly where the first ended.
    private static let order = "ORDER BY r.ZDATE DESC, r.Z_PK DESC"

    /// One page of the calls that match `filter`, newest first, and how many match in all.
    ///
    /// Without an address filter the database does the paging: a `COUNT` and a `LIMIT`.
    /// With one, every call has to be looked at, so the rows are streamed and only the
    /// page is kept; memory stays the size of the page however long the history is.
    func page(_ filter: CallFilter, limit: Int, offset: Int) throws -> (calls: [CallRecord], total: Int) {
        let (clause, binds) = restriction(filter)
        func bindFilter(_ statement: OpaquePointer) {
            for (index, bind) in binds.enumerated() { bind(statement, Int32(index + 1)) }
        }

        guard let wanted = filter.addresses else {
            var total = 0
            try query("SELECT COUNT(*) FROM \(Self.recordTable) r \(clause)", bind: bindFilter) {
                total = Int(Self.integer($0, 0) ?? 0)
            }
            var rows: [Row] = []
            try query(
                "\(try selectColumns()) \(clause) \(Self.order) LIMIT ? OFFSET ?",
                bind: { statement in
                    bindFilter(statement)
                    sqlite3_bind_int64(statement, Int32(binds.count + 1), Int64(limit))
                    sqlite3_bind_int64(statement, Int32(binds.count + 2), Int64(offset))
                }
            ) { statement in
                if let row = Row(statement) { rows.append(row) }
            }
            let byCall = try participants(forCalls: rows.map(\.id))
            return (rows.map { $0.record(participants: byCall[$0.id] ?? []) }, total)
        }

        let byCall = try participants()
        var total = 0
        var kept: [CallRecord] = []
        try query("\(try selectColumns()) \(clause) \(Self.order)", bind: bindFilter) { statement in
            guard let row = Row(statement) else { return }
            let record = row.record(participants: byCall[row.id] ?? [])
            guard record.remoteAddresses.contains(where: { AddressKey($0).map(wanted.contains) ?? false })
            else { return }
            if total >= offset && kept.count < limit { kept.append(record) }
            total += 1
        }
        return (kept, total)
    }

    /// One call by id, or `nil`.
    func record(id: Int64) throws -> CallRecord? {
        var found: Row?
        try query(
            "\(try selectColumns()) WHERE r.Z_PK = ?",
            bind: { sqlite3_bind_int64($0, 1, id) }
        ) { statement in
            found = Row(statement)
        }
        guard let found else { return nil }
        return found.record(participants: try participants(forCalls: [id])[id] ?? [])
    }
}
