import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Every tool here reads; none carries a verb prefix.
public enum ToolCatalog {

    public static let statusName = "phone_status"
    public static let listName = "calls_list"
    public static let getName = "call_get"

    // The bounds. The schemas, the descriptions and the server instructions quote these by
    // interpolation, so what a caller is told is what the code enforces. Each maximum is a
    // number of rows of ordinary width that fits `ToolStandard.longestResult` with room to
    // spare, and each default makes a call with no argument about `ToolStandard.usualPage`
    // or less; `BoundsTests` renders a full page of the widest ordinary rows to hold both.

    /// A call id is a row number of the history database, counted from one. The upper end
    /// is the largest whole number every JSON client reads back exactly.
    public static let callIDRange = 1...9_007_199_254_740_991

    public static let offsetRange = 0...10_000_000
    public static let listLimitRange = 1...100
    public static let defaultListLimit = 50

    /// The participants of one call, paged in `call_get`.
    public static let participantLimitRange = 1...100
    public static let defaultParticipantLimit = 20

    /// The widest the other parties of one row of `calls_list` get before they are clipped.
    /// A group call can have many; `call_get` lists them all, a page at a time.
    public static let partiesWidth = 100

    public static func all() -> [Tool] {
        [status, list, get]
    }

    /// The argument names a tool's schema lists, which are the only ones it accepts.
    static func argumentNames(of toolName: String) -> [String]? {
        guard let tool = all().first(where: { $0.name == toolName }),
            case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return nil }
        return properties.keys.sorted()
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

    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
            "default": .int(def),
        ])
    }

    private static func identifier(_ description: String, range: ClosedRange<Int>) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
        ])
    }

    private static func offsetHelp(_ things: String) -> String {
        "Number of \(things) to skip. A result that leaves some out says which offset returns "
            + "the next page."
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset). A date that does not exist is refused.
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
            binary to add to Full Disk Access. Lists no calls. The result is short and fixed in size.

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
            Returns one page of calls, NEWEST FIRST, \(defaultListLimit) by default (at most \
            \(listLimitRange.upperBound)): date and time, direction (incoming, outgoing, \
            missed), kind (phone, FaceTime audio, FaceTime video), duration, the other party's \
            number or address, the contact's name when Contacts knows it, and the call's id. \
            When calls exist that the page does not hold, its first lines say how many there \
            are and the offset of the next page: pass limit and offset. The other parties of \
            a group call are clipped to \(partiesWidth) characters in a row; call_get lists \
            them all.

            Filters combine with AND. from_date and to_date are both inclusive, and to_date \
            written as a day covers that whole day. 'missed' means incoming and not answered — \
            a declined call and one that rang out look the same in the history. Whether an \
            OUTGOING call was answered is not recorded at all, so it is never reported.

            The history is the one shared with the iPhone signed in to the same Apple \
            Account, and it covers only as far back as the system keeps; phone_status says \
            how far that is.
            """,
        inputSchema: object(properties: [
            "from_date": string("Earliest call, inclusive. \(dateHelp)"),
            "to_date": string(
                "Latest call, inclusive at the precision written: a day covers the whole day, "
                    + "a time to the minute covers that whole minute. " + dateHelp),
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
                "Maximum number of calls in one page.", range: listLimitRange,
                default: defaultListLimit),
            "offset": integer(offsetHelp("calls"), range: offsetRange, default: 0),
        ]),
        annotations: readOnly
    )

    static let get = Tool(
        name: getName,
        title: "Read one call",
        description: """
            Returns every field the history keeps for one call: the service that carried it, \
            the country code, the name cached at call time, the raw disconnect cause, and the \
            participants. A group call can have many, so they come a page at a time, \
            \(defaultParticipantLimit) by default (at most \(participantLimitRange.upperBound)), \
            in the order the history lists them; when some are left out, the first lines say \
            how many exist and the offset of the next page: pass limit and offset.

            Needs an id from calls_list. Ids are row numbers in the local database and can \
            change if the system rebuilds it, so look one up again rather than reusing it \
            from an earlier conversation.
            """,
        inputSchema: object(
            properties: [
                "call_id": identifier("Id returned by calls_list.", range: callIDRange),
                "limit": integer(
                    "Maximum number of participants in one page.", range: participantLimitRange,
                    default: defaultParticipantLimit),
                "offset": integer(
                    offsetHelp("participants"), range: offsetRange, default: 0),
            ],
            required: ["call_id"]),
        annotations: readOnly
    )
}
