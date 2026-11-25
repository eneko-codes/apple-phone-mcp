import Foundation

/// The seam between the tool layer and the call history database.
///
/// Everything above this protocol is exercised by the tests against an in-memory double;
/// everything below it is exercised against a database the suite invents. The owner's
/// real history is reached only by `SystemCallStore` with its default path.
public protocol CallStore: Sendable {
    func access() -> DatabaseAccess
    func status() async throws -> StoreStatus

    /// Newest first, one page: at most `limit` calls from `offset`. `total` counts every
    /// match, not just the page. The page is cut at the source, never loaded whole first.
    func calls(_ filter: CallFilter, limit: Int, offset: Int) async throws -> CallPage

    /// `nil` when no call has that id.
    func call(id: Int64) async throws -> CallRecord?
}

/// The seam between the tool layer and Contacts.framework. Used only to put a name beside
/// a number and to turn a name into numbers; it never writes.
public protocol ContactResolver: Sendable {
    func authorization() -> ContactsAuthorization

    /// Prompts on first use. Returns the status after the person answers.
    @discardableResult
    func requestAccess() async -> ContactsAuthorization

    /// A display name for every address that belongs to a contact. Addresses with no
    /// contact are absent from the result.
    func names(for addresses: [String]) async throws -> [AddressKey: String]

    /// Every phone number and email of each contact whose name contains `name`.
    func addresses(matching name: String) async throws -> [(name: String, addresses: [String])]
}
