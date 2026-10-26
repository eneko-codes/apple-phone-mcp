import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
///
/// Nothing here is an edit: this server never modifies a call record, so an absent
/// argument simply means the filter is not applied.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Clamps rather than rejects: a model asking for 500 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    /// A row id. Unlike a limit this is never clamped — a wrong id must fail, not resolve
    /// to a neighbouring call.
    public func requiredID(_ name: String) throws -> Int64 {
        guard let raw = values[name] else { throw ToolError.missingArgument(name) }
        if let number = raw.intValue { return Int64(number) }
        // Large integers survive some clients as strings, and refusing one would be a
        // technicality rather than a safeguard.
        if let text = raw.stringValue, let number = Int64(text) { return number }
        throw ToolError.badArgument(name: name, reason: "a numeric id from calls_list was expected")
    }

    /// One of a fixed set of spellings, or absent. A misspelling is refused rather than
    /// ignored: ignoring it would silently widen the filter to every call.
    public func optionalChoice(_ name: String, from choices: [String]) throws -> String? {
        guard let value = optionalString(name)?.lowercased() else { return nil }
        guard choices.contains(value) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected one of \(choices.map { "\"\($0)\"" }.joined(separator: ", "))")
        }
        return value
    }

    /// `to` given as a plain day covers that whole day.
    ///
    /// Without this, "from 2026-08-01 to 2026-08-12" would stop at midnight and drop
    /// every call on the 12th.
    public func optionalDate(_ name: String, endOfDayIfDayOnly: Bool = false) throws -> Date? {
        guard let raw = optionalString(name) else { return nil }
        let parsed = try DateParsing.parse(raw, argument: name, calendar: calendar)
        guard endOfDayIfDayOnly, parsed.isDateOnly else { return parsed.date }
        return calendar.date(byAdding: .day, value: 1, to: parsed.date) ?? parsed.date
    }
}
