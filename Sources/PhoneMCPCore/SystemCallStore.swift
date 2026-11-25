import Foundation

/// The only type that touches the call history on this Mac. Below it is the owner's real
/// database; above it, everything runs against a double.
///
/// The Phone app exposes no framework, no scripting dictionary and no public intent that
/// lists past calls, so the database `callservicesd` writes is the only complete source —
/// and it costs the broadest permission on the Mac, Full Disk Access.
public struct SystemCallStore: CallStore {

    private let databasePath: String

    /// Re-exported because `CallHistoryDatabase` is deliberately internal — the SQLite
    /// layer is not part of this module's surface, and a public default argument cannot
    /// name an internal type.
    public static var defaultDatabasePath: String { CallHistoryDatabase.defaultPath }

    /// The path is injectable only so the store can be exercised against a database the
    /// tests build. Nothing in the running server passes anything but the default.
    public init(databasePath: String = SystemCallStore.defaultDatabasePath) {
        self.databasePath = databasePath
    }

    public func access() -> DatabaseAccess {
        CallHistoryDatabase.probeAccess(path: databasePath)
    }

    /// Opened per call rather than held.
    ///
    /// A long-lived handle would keep a read lock's worth of state on a file another
    /// process is actively writing for the life of this process, and there is no cache
    /// worth keeping warm for a history this size.
    private func open() throws -> CallHistoryDatabase {
        let database = try CallHistoryDatabase(path: databasePath)
        try database.verifySchema()
        return database
    }

    public func status() async throws -> StoreStatus {
        let access = access()
        guard access.isUsable else {
            return StoreStatus(access: access, databasePath: databasePath)
        }

        let database = try open()
        return try database.read {
            let range = try database.dateRange()
            return StoreStatus(
                access: .granted,
                databasePath: databasePath,
                callCount: try database.callCount(),
                oldestCall: range.oldest,
                newestCall: range.newest,
                missingOptionalColumns: try database.missingOptionalColumns(),
                walBytes: walBytes())
        }
    }

    public func calls(_ filter: CallFilter, limit: Int, offset: Int) async throws -> CallPage {
        let database = try open()
        let found = try database.read { try database.page(filter, limit: limit, offset: offset) }
        return CallPage(calls: found.calls, total: found.total)
    }

    public func call(id: Int64) async throws -> CallRecord? {
        let database = try open()
        return try database.read { try database.record(id: id) }
    }

    /// Read with `stat`, which does not open the file.
    private func walBytes() -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath + "-wal")
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}
