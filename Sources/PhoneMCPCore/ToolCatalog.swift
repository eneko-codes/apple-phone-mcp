import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Every tool here reads; none carries a verb prefix.
public enum ToolCatalog {

    public static let statusName = "phone_status"
    public static let listName = "calls_list"
    public static let getName = "call_get"

    public static func all() -> [Tool] {
        [status, list, get]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// Every property here declares one scalar `type`, never a union such as
    /// `["string", "null"]`. Claude Desktop's schema sanitiser drops a property whose
    /// `type` is an array and hands the model a bare `{}` instead. A test walks the whole
    /// catalogue to keep unions out.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func choice(_ description: String, _ values: [String]) -> Value {
        .object([
            "type": .string("string"), "description": .string(description),
            "enum": .array(values.map { .string($0) }),
        ])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static func identifier(_ description: String) -> Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    static let directionChoices = CallDirection.allCases.map(\.rawValue)
    static let kindChoices = CallKind.filterable.map(\.label)

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "Phone access status",
        description: """
            Reports whether this server can read the call history and Contacts, how many \
            calls the history holds and the span they cover, and the exact path of the \
            binary to add to Full Disk Access. Lists no calls.

            Use it when another tool fails on permissions, or when setting the server up. \
            Do not use it to look for calls.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly
    )

    static let list = Tool(
        name: listName,
        title: "List calls",
        description: """
            Lists calls NEWEST FIRST: date and time, direction (incoming, outgoing, missed), \
            kind (phone, FaceTime audio, FaceTime video), duration, the other party's number \
            or address, the contact's name when Contacts knows it, and the call's id.

            Filters combine with AND. 'missed' means incoming and not answered — a declined \
            call and one that rang out look the same in the history. Whether an OUTGOING \
            call was answered is not recorded at all, so it is never reported.

            The history is the one shared with the iPhone signed in to the same Apple \
            Account, and it covers only as far back as the system keeps; phone_status says \
            how far that is.
            """,
        inputSchema: object(properties: [
            "from": string("Earliest call, inclusive. \(dateHelp)"),
            "to": string(
                "Latest call, exclusive — except a plain day, which covers that whole day. "
                    + dateHelp),
            "direction": choice("Only calls in this direction.", directionChoices),
            "kind": choice("Only calls of this kind.", kindChoices),
            "number": string(
                "A phone number or Apple Account email. Numbers are compared on their last "
                    + "nine digits, so spacing and a missing country code do not matter."),
            "contact": string(
                "A name from Contacts, matched the way Contacts' own name search matches. "
                    + "Every number and email of each matching contact is searched. Needs "
                    + "Contacts access."),
            "limit": integer(
                "Maximum number of calls to return.",
                minimum: Configuration.listLimitRange.lowerBound,
                maximum: Configuration.listLimitRange.upperBound,
                default: Configuration.listLimit),
            "offset": integer(
                "Skip this many calls; use it to page.",
                minimum: Configuration.offsetRange.lowerBound,
                maximum: Configuration.offsetRange.upperBound, default: 0),
        ]),
        annotations: readOnly
    )

    static let get = Tool(
        name: getName,
        title: "Read one call",
        description: """
            Returns every field the history keeps for one call: all participants of a group \
            call, the service that carried it, the country code, the name cached at call \
            time and the raw disconnect cause.

            Needs an id from calls_list. Ids are row numbers in the local database and can \
            change if the system rebuilds it, so look one up again rather than reusing it \
            from an earlier conversation.
            """,
        inputSchema: object(
            properties: ["call_id": identifier("Id returned by calls_list.")],
            required: ["call_id"]),
        annotations: readOnly
    )
}
