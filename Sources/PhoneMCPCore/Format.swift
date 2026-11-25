import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    func timestampWithYear(_ date: Date) -> String {
        DateParsing.dayWithYear(date, calendar: calendar) + " "
            + DateParsing.time(date, calendar: calendar)
    }

    /// `0s`, `45s`, `3m 12s`, `1h 02m`. Rounded to the second: the store keeps fractions
    /// nobody reads.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }

    static func kind(_ kind: CallKind) -> String {
        switch kind {
        case .phone: "phone"
        case .facetimeAudio: "FaceTime audio"
        case .facetimeVideo: "FaceTime video"
        case .other(let value): "unknown kind \(value)"
        }
    }

    /// `Ane Example (+12125550101)`, or the address alone when no contact has it.
    static func party(_ address: String, names: [AddressKey: String]) -> String {
        guard let key = AddressKey(address), let name = names[key] else { return address }
        return "\(name) (\(address))"
    }

    static func parties(_ record: CallRecord, names: [AddressKey: String]) -> String {
        guard !record.remoteAddresses.isEmpty else { return "(no number recorded)" }
        return record.remoteAddresses.map { party($0, names: names) }.joined(separator: ", ")
    }

    // MARK: Tools

    public func status(
        _ status: StoreStatus, contacts: ContactsAuthorization, binaryPath: String
    ) -> String {
        var lines = ["\(PhoneMCPServer.name) \(PhoneMCPServer.version)"]

        lines.append("")
        lines.append("READ · local call history database")
        lines.append(
            Self.block([
                ("access", ToolError.accessMessage(status.access).split(separator: "\n").first.map(String.init)),
                ("database", status.databasePath),
                ("opened", "read-only, through the write-ahead log (never writes)"),
                ("calls", status.callCount.map(String.init)),
                ("oldest", status.oldestCall.map(timestampWithYear)),
                ("newest", status.newestCall.map(timestampWithYear)),
                ("write-ahead log", status.walBytes.map { "\($0) bytes, read on every call" }),
                ("missing columns",
                 status.missingOptionalColumns.isEmpty
                    ? nil : status.missingOptionalColumns.joined(separator: ", ")),
            ]))

        lines.append("")
        lines.append("CONTACTS · names beside numbers")
        lines.append(
            Self.block([
                ("access", ToolError.describe(contacts)),
                ("without it", "numbers are shown alone, and the 'contact' filter refuses"),
            ]))

        lines.append("")
        lines.append("LIMITS")
        lines.append(
            Self.block([
                ("calls per page", "\(ToolCatalog.defaultListLimit) (at most \(ToolCatalog.listLimitRange.upperBound))"),
                ("participants per page", "\(ToolCatalog.defaultParticipantLimit) (at most \(ToolCatalog.participantLimitRange.upperBound))"),
                ("time limit", "\(PhoneTools.defaultTimeout.components.seconds) seconds per call"),
            ]))

        lines.append("")
        lines.append("  binary  \(binaryPath)")

        if !status.access.isUsable {
            lines.append("")
            lines.append(ToolError.accessMessage(status.access))
        }
        if !contacts.isUsable {
            lines.append("")
            lines.append(ToolError.contactsMessage(contacts))
        }
        return lines.joined(separator: "\n")
    }

    /// The width of the other parties in a listing row, with the clip marked.
    static func clipped(_ text: String, to width: Int) -> (text: String, wasClipped: Bool) {
        guard text.count > width else { return (text, false) }
        return (String(text.prefix(width - 1)) + "…", true)
    }

    /// `rows` are the calls of one page, `total` how many match across the whole history.
    /// The caller has already placed the page: `offset` is where its first row sits, and the
    /// result starts with the sentence that says what the page leaves out.
    public func calls(
        _ rows: [CallRecord], total: Int, offset: Int, names: [AddressKey: String],
        described: [String], notices: [String]
    ) -> String {
        let header =
            "\(total) call\(total == 1 ? "" : "s")"
            + (described.isEmpty ? "" : " · " + described.joined(separator: " · "))
            + " · newest first"
        let position = Notice.page(offset: offset, count: rows.count, total: total, things: "calls")
        guard !rows.isEmpty else {
            let empty = total == 0
                ? header + "\nNothing matched. calls_list with no filters lists every call."
                : header
            return ToolStandard.withNotices(notices + [position].compactMap { $0 }, empty)
        }

        var anyClipped = false
        var lines = [header, ""]
        for record in rows {
            let parties = Self.clipped(
                Self.parties(record, names: names), to: ToolCatalog.partiesWidth)
            anyClipped = anyClipped || parties.wasClipped
            lines.append(
                "\(timestampWithYear(record.date)) · \(Self.pad(record.direction.rawValue, to: 8))"
                    + " · \(Self.kind(record.kind)) · \(Self.duration(record.duration))"
                    + " · \(parties.text) · id \(record.id)")
        }
        let clipNotice = anyClipped
            ? [Notice.clipped(field: "The other parties", width: ToolCatalog.partiesWidth, tool: ToolCatalog.getName)]
            : []
        return ToolStandard.withNotices(
            notices + [position].compactMap { $0 } + clipNotice, lines.joined(separator: "\n"))
    }

    /// `participants` are the addresses of one page of the call's other parties, and
    /// `participantOffset` where that page starts among all of them.
    public func call(
        _ record: CallRecord, participants: [String], participantOffset: Int,
        participantTotal: Int, names: [AddressKey: String], notices: [String]
    ) -> String {
        let answered: String? =
            switch (record.direction, record.answered) {
            case (.outgoing, _): "not recorded for outgoing calls"
            case (_, true?): "yes"
            case (_, false?): "no"
            case (_, nil): nil
            }
        let position = Notice.page(
            offset: participantOffset, count: participants.count, total: participantTotal,
            things: "participants")
        let body = [
            "Call \(record.id)",
            Self.block([
                ("date", timestampWithYear(record.date)),
                ("direction", record.direction.rawValue),
                ("answered", answered),
                ("kind", Self.kind(record.kind)),
                ("duration", Self.duration(record.duration)),
                ("with", participantTotal == 0
                    ? "(no number recorded)"
                    : participants.isEmpty
                        ? nil
                        : participants.map { Self.party($0, names: names) }
                            .joined(separator: "\n")),
                ("name at call time", record.storedName),
                ("service", record.serviceProvider),
                ("country", record.countryCode),
                ("disconnect cause", record.disconnectedCause.map { "\($0) (undocumented code)" }),
                ("unique id", record.uniqueID),
            ]),
        ].joined(separator: "\n")
        return ToolStandard.withNotices(notices + [position].compactMap { $0 }, body)
    }
}
