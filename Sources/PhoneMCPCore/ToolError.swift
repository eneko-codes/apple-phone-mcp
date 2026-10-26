import Foundation

public enum ToolError: Error, Equatable {
    case notAuthorized(DatabaseAccess)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case endBeforeStart
    case callNotFound(id: Int64)
    case contactsUnavailable(ContactsAuthorization)
    case contactNotFound(name: String)
    case schemaUnsupported(table: String, missing: [String])
    case storeFailure(String)

    public var message: String {
        switch self {
        case .notAuthorized(let access):
            return Self.accessMessage(access)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use one of:
                \(DateParsing.acceptedForms)

                A plain day given as 'to' covers that whole day.
                """

        case .endBeforeStart:
            return "'to' is before 'from'. A range cannot end before it begins."

        case .callNotFound(let id):
            return """
                No call exists with id \(id).

                Call ids are row numbers in the local call history database. The system can
                rebuild that database and renumber it, and a call deleted in the Phone app
                takes its id with it. Call calls_list again rather than reusing an id from an
                earlier conversation.
                """

        case .contactsUnavailable(let authorization):
            return """
                The 'contact' filter needs access to Contacts, and it is \
                \(Self.describe(authorization)).

                \(Self.contactsMessage(authorization))

                Filtering by 'number' works without Contacts.
                """

        case .contactNotFound(let name):
            return """
                No contact's name matches '\(name)', or the contacts that match have no phone
                number or email to look for.

                The name is matched by Contacts' own name search, not by this server. Try a
                first or last name on its own, or filter by 'number' if the person is not in
                Contacts.
                """

        case .schemaUnsupported(let table, let missing):
            return """
                The call history database is not the shape this server understands: table
                '\(table)' has no column \(missing.map { "'\($0)'" }.joined(separator: ", ")).

                This schema is Apple's private Core Data model, and it changes between
                releases. That is a bug in this server, not something to configure — the
                columns it depends on are pinned in its test suite against a fixture
                database, and one of them has moved.
                """

        case .storeFailure(let detail):
            return "The call history database returned an error: \(detail)"
        }
    }

    static func describe(_ authorization: ContactsAuthorization) -> String {
        switch authorization {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted by a profile or Screen Time"
        case .notDetermined: "not yet decided"
        }
    }

    static func contactsMessage(_ authorization: ContactsAuthorization) -> String {
        switch authorization {
        case .authorized:
            return "Contacts access granted; numbers are shown with the contact's name."
        case .notDetermined:
            return """
                Contacts access has not been asked for yet. The first calls_list or call_get
                asks for it with a macOS dialog; until it is answered, numbers are shown
                without names.
                """
        case .denied, .restricted:
            return """
                Contacts access is off, so numbers are shown without names. To turn it on:
                  System Settings → Privacy & Security → Contacts → enable "apple-phone-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Contactos)
                Then quit and reopen Claude Desktop.
                """
        }
    }

    static func accessMessage(_ access: DatabaseAccess) -> String {
        switch access {
        case .granted:
            return "Full Disk Access granted; the call history database is readable."

        case .denied:
            return """
                No access to the call history: macOS refused to open it.

                ~/Library/Application Support/CallHistoryDB is behind FULL DISK ACCESS. Unlike
                Contacts there is no consent dialog for it and no Info.plist key that can
                ask — it is granted by hand, once, and it cannot be requested by any process:

                  System Settings → Privacy & Security → Full Disk Access →
                  "+" → add the server binary → enable "apple-phone-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad →
                   Acceso total al disco)

                The binary to add is the one Claude Desktop runs, under
                  ~/Library/Application Support/Claude/Claude Extensions/
                Call phone_status to print the exact path this process was launched from.

                Then quit and reopen Claude Desktop: the grant is resolved when the process
                starts, so a server already running will keep failing until it is restarted.
                """

        case .missing(let path):
            return """
                No call history database at \(path).

                Either no call has ever been made or received on this Mac or synced to it,
                or the file has moved in this macOS release. Nothing here can create it.

                Note that a missing file and a forbidden one look alike from outside: if
                Full Disk Access is not granted, the parent directory cannot even be listed.
                """

        case .failed(let detail):
            return """
                Could not open the call history database: \(detail)

                The file is opened read-only; this server never writes to it. An error here
                means something else: a corrupt file, or a database written by a newer SQLite
                than this binary links against.
                """
        }
    }
}
