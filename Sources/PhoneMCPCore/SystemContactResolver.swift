import Contacts
import Foundation

/// `ContactResolver` backed by the real address book. Reads only: no `CNSaveRequest`
/// exists anywhere in this server.
public struct SystemContactResolver: ContactResolver {

    /// One `CNContactStore` for the whole process. `CNContactStore.h` documents it as
    /// thread safe.
    nonisolated(unsafe) private static let shared = CNContactStore()

    public init() {}

    public func authorization() -> ContactsAuthorization {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    @discardableResult
    public func requestAccess() async -> ContactsAuthorization {
        _ = try? await Self.shared.requestAccess(for: .contacts)
        return authorization()
    }

    private static var keys: [CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
    }

    /// A contact with no personal name is shown by its organisation, as Contacts.app does.
    private static func displayName(_ contact: CNContact) -> String? {
        if let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty {
            return name
        }
        return contact.organizationName.isEmpty ? nil : contact.organizationName
    }

    private static func addresses(of contact: CNContact) -> [String] {
        contact.phoneNumbers.map(\.value.stringValue)
            + contact.emailAddresses.map { $0.value as String }
    }

    /// Walks the whole address book once per call rather than holding an index: a cache
    /// would go stale the moment a contact is edited, and an address book walk is cheap
    /// next to a tool call.
    public func names(for addresses: [String]) async throws -> [AddressKey: String] {
        let wanted = Set(addresses.compactMap(AddressKey.init))
        guard !wanted.isEmpty else { return [:] }

        var found: [AddressKey: String] = [:]
        let request = CNContactFetchRequest(keysToFetch: Self.keys)
        try Self.shared.enumerateContacts(with: request) { contact, stop in
            guard let name = Self.displayName(contact) else { return }
            for address in Self.addresses(of: contact) {
                guard let key = AddressKey(address), wanted.contains(key) else { continue }
                // First contact wins, so a number shared by two cards always resolves to
                // the same name.
                if found[key] == nil { found[key] = name }
            }
            if found.count == wanted.count { stop.pointee = true }
        }
        return found
    }

    public func addresses(matching name: String) async throws -> [(
        name: String, addresses: [String]
    )] {
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts = try Self.shared.unifiedContacts(matching: predicate, keysToFetch: Self.keys)
        return contacts.compactMap { contact in
            guard let display = Self.displayName(contact) else { return nil }
            return (display, Self.addresses(of: contact))
        }
    }
}
