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
                ("list limit", "\(Configuration.listLimit) (at most \(Configuration.listLimitRange.upperBound))"),
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

    public func calls(
        _ page: CallPage, names: [AddressKey: String], filter: CallFilter, described: [String],
        offset: Int
    ) -> String {
        var scope = described
        if let direction = filter.direction { scope.insert(direction.rawValue, at: 0) }
        if let kind = filter.kind { scope.insert(Self.kind(kind), at: 0) }
        if let from = filter.from {
            scope.append("from \(DateParsing.roundTrip(from, calendar: calendar))")
        }
        if let to = filter.to {
            scope.append("before \(DateParsing.roundTrip(to, calendar: calendar))")
        }

        let header =
            "\(page.total) call\(page.total == 1 ? "" : "s")"
            + (scope.isEmpty ? "" : " · " + scope.joined(separator: " · "))
        guard !page.calls.isEmpty else {
            return offset > 0 && page.total > 0
                ? header + "\nNo calls past offset \(offset)."
                : header + "\nNothing matched. calls_list with no filters lists every call."
        }

        var lines = [
            header,
            "showing \(offset + 1)–\(offset + page.calls.count), newest first",
            "",
        ]
        for record in page.calls {
            lines.append(
                "\(timestampWithYear(record.date)) · \(Self.pad(record.direction.rawValue, to: 8))"
                    + " · \(Self.kind(record.kind)) · \(Self.duration(record.duration))"
                    + " · \(Self.parties(record, names: names)) · id \(record.id)")
        }
        let next = offset + page.calls.count
        if next < page.total {
            lines.append("")
            lines.append("More: call again with offset=\(next).")
        }
        return lines.joined(separator: "\n")
    }

    public func call(_ record: CallRecord, names: [AddressKey: String]) -> String {
        let answered: String? =
            switch (record.direction, record.answered) {
            case (.outgoing, _): "not recorded for outgoing calls"
            case (_, true?): "yes"
            case (_, false?): "no"
            case (_, nil): nil
            }
        return [
            "Call \(record.id)",
            Self.block([
                ("date", timestampWithYear(record.date)),
                ("direction", record.direction.rawValue),
                ("answered", answered),
                ("kind", Self.kind(record.kind)),
                ("duration", Self.duration(record.duration)),
                ("with", record.remoteAddresses.isEmpty
                    ? "(no number recorded)"
                    : record.remoteAddresses.map { Self.party($0, names: names) }
                        .joined(separator: "\n")),
                ("name at call time", record.storedName),
                ("service", record.serviceProvider),
                ("country", record.countryCode),
                ("disconnect cause", record.disconnectedCause.map { "\($0) (undocumented code)" }),
                ("unique id", record.uniqueID),
            ]),
        ].joined(separator: "\n")
    }
}
