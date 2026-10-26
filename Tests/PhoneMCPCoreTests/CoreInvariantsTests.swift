import Foundation
import Testing

@testable import PhoneMCPCore

@Suite("Core invariants")
struct CoreInvariantsTests {

    @Test("The database URI is read-only and never immutable")
    func uriIsReadOnly() {
        let uri = CallHistoryDatabase.uri(forPath: "/Users/user/Library/CallHistory.storedata")
        #expect(uri == "file:/Users/user/Library/CallHistory.storedata?mode=ro")
        // immutable=1 would skip the write-ahead log and hide the newest calls.
        #expect(!uri.contains("immutable"))
    }

    @Test("immutable is used only when no process has the database open")
    func immutableOnlyWithoutSidecars() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-phone-mcp-sidecars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("CallHistory.storedata").path

        #expect(CallHistoryDatabase.openingURI(forPath: path).hasSuffix("?mode=ro&immutable=1"))
        FileManager.default.createFile(atPath: path + "-wal", contents: Data())
        #expect(CallHistoryDatabase.openingURI(forPath: path).hasSuffix("?mode=ro&immutable=1"))
        FileManager.default.createFile(atPath: path + "-shm", contents: Data())
        #expect(CallHistoryDatabase.openingURI(forPath: path).hasSuffix("?mode=ro"))
    }

    @Test("A path cannot smuggle in its own query string")
    func pathCannotChangeTheMode() {
        let uri = CallHistoryDatabase.uri(forPath: "/tmp/odd?mode=rw#x%")
        #expect(uri.hasSuffix("?mode=ro"))
        #expect(uri.components(separatedBy: "?").count == 2)
        #expect(!uri.contains("#"))
    }

    @Test("A permission refusal is told apart from a missing file")
    func errnoClassification() {
        #expect(CallHistoryDatabase.classify(errno: EPERM, path: "/x") == .denied)
        #expect(CallHistoryDatabase.classify(errno: EACCES, path: "/x") == .denied)
        #expect(CallHistoryDatabase.classify(errno: ENOENT, path: "/x") == .missing(path: "/x"))
        #expect(CallHistoryDatabase.isPermissionDenied(code: 23, systemErrno: 0))  // SQLITE_AUTH
        #expect(CallHistoryDatabase.isPermissionDenied(code: 14, systemErrno: EPERM))
        #expect(!CallHistoryDatabase.isPermissionDenied(code: 14, systemErrno: ENOENT))
    }

    @Test("Direction is derived from who placed the call and whether it was answered")
    func directionMapping() {
        #expect(CallDirection.from(originated: true, answered: false) == .outgoing)
        #expect(CallDirection.from(originated: true, answered: true) == .outgoing)
        #expect(CallDirection.from(originated: false, answered: true) == .incoming)
        #expect(CallDirection.from(originated: false, answered: false) == .missed)
    }

    @Test("Call kinds round-trip, and an unknown kind is kept rather than guessed")
    func kindMapping() {
        #expect(CallKind(rawValue: 1) == .phone)
        #expect(CallKind(rawValue: 8) == .facetimeVideo)
        #expect(CallKind(rawValue: 16) == .facetimeAudio)
        #expect(CallKind(rawValue: 32) == .other(32))
        #expect(CallKind(rawValue: 32).rawValue == 32)
    }

    @Test("Addresses compare on their last nine digits, emails case-insensitively")
    func addressKeys() {
        #expect(AddressKey("+1 212 555 0101") == AddressKey("2125550101"))
        #expect(AddressKey("(212) 555-0101") == AddressKey("+12125550101"))
        #expect(AddressKey("2125550101") != AddressKey("2125550102"))
        #expect(AddressKey("Ane@Example.com") == AddressKey("ane@example.com"))
        // Short codes are compared whole.
        #expect(AddressKey("1004") != AddressKey("21004"))
        #expect(AddressKey("") == nil)
        #expect(AddressKey("unknown") == nil)
    }

    @Test("Durations read the way a person says them")
    func durations() {
        #expect(Format.duration(0) == "0s")
        #expect(Format.duration(45.4) == "45s")
        #expect(Format.duration(192) == "3m 12s")
        #expect(Format.duration(3720) == "1h 02m")
    }
}
