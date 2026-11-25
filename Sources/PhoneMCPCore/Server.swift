import Foundation

public enum PhoneMCPServer {

    public static let name = "apple-phone-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: which permission governs what, where the history comes from, and which of its
    /// fields are inferences rather than stored facts.
    public static let instructions = """
        Read-only access to the call history of the Phone app on this Mac.

        The history comes from the local call history database, opened read-only. That \
        file is protected, so every tool except phone_status needs Full Disk Access granted \
        by hand in System Settings — there is no permission dialog for it and no Info.plist \
        key that asks. phone_status says whether it is granted and what to do if not.

        It is the history shared with the iPhone signed in to the same Apple Account, not \
        only calls taken on this Mac, and it reaches back only as far as the system keeps; \
        phone_status gives the oldest call. The newest calls are included: reads go through \
        the database's write-ahead log.

        Names come from Contacts, which asks for its own permission the first time a call \
        is listed. Without it every tool still works, showing numbers alone, except the \
        'contact' filter.

        Two fields are inferred, not stored. 'missed' means incoming and not answered — a \
        declined call and one that rang out look the same. Whether an OUTGOING call was \
        answered is not recorded at all, so it is never reported; a duration above zero is \
        the only sign it connected. There is no record of which device took a call.

        Workflow: calls_list to find calls, call_get for every field of one. Ids are row \
        numbers in the local database and can change if the system rebuilds it, so look \
        them up again rather than reusing one from earlier in the conversation. Totals, \
        counts per person and other summaries are yours to compute from calls_list rows.

        LISTS COME IN PAGES. calls_list returns \(ToolCatalog.defaultListLimit) calls by \
        default, newest first, and at most \(ToolCatalog.listLimitRange.upperBound); \
        call_get lists the participants of a group call \(ToolCatalog.defaultParticipantLimit) \
        at a time, at most \(ToolCatalog.participantLimitRange.upperBound). When a result \
        leaves some out, its first lines say how many exist and the offset of the next \
        page: pass limit and offset. Narrow with from_date and to_date, both inclusive. A \
        limit or offset outside its range is moved to the nearest allowed value and the \
        first lines say which was used; a call id outside its range is refused, and so is an \
        argument the tool does not list.

        EVERY CALL IS BOUNDED. One that has not finished after \
        \(PhoneTools.defaultTimeout.components.seconds) seconds is abandoned and answered \
        with an error saying so; nothing is changed, because nothing is ever written. Retry \
        with a narrower call.

        This server never modifies or deletes a call, never places one and never writes to \
        Contacts.
        """

    /// The stores are parameters so the whole server can be driven by doubles. Nothing in
    /// this function opens a database or the address book by itself.
    public static func run(
        store: any CallStore = SystemCallStore(),
        contacts: any ContactResolver = SystemContactResolver()
    ) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(
            handler: handler(tools: PhoneTools(store: store, contacts: contacts)))
    }

    public static func handler(tools: PhoneTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
