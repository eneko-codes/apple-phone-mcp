import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a quantity can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool puts `notices` before the data.
///
/// Nothing here is an edit: this server never modifies a call record, so an absent
/// argument simply means the filter is not applied.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each quantity that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// Refuses a name the tool's schema does not list. Without it a caller still using a
    /// renamed argument would run an unfiltered call and read the answer as filtered.
    public func refuseUnknown(allowed: [String]) throws {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        guard let first = unknown.first else { return }
        throw ToolError.unknownArgument(name: first, allowed: allowed)
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func wholeNumber(_ name: String) throws -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return number
    }

    /// A quantity: a page size, a count to skip. Outside its range it is moved to the
    /// nearest allowed value, and `notices` gains the sentence that says which was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let number = try wholeNumber(name) else { return fallback }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int)
    {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    /// A row id. Unlike a quantity this is never moved — a wrong id must fail, not resolve
    /// to a neighbouring call.
    public func requiredID(_ name: String, in range: ClosedRange<Int>) throws -> Int64 {
        guard let number = try wholeNumber(name) else { throw ToolError.missingArgument(name) }
        guard range.contains(number) else {
            throw ToolError.badArgument(
                name: name,
                reason: "a whole number from \(range.lowerBound) to \(range.upperBound) was "
                    + "expected, as returned by calls_list")
        }
        return Int64(number)
    }

    /// One of a fixed set of spellings, or absent. A misspelling is refused rather than
    /// ignored: ignoring it would silently widen the filter to every call.
    public func optionalChoice(_ name: String, from choices: [String]) throws -> String? {
        guard let value = try optionalString(name)?.lowercased() else { return nil }
        guard choices.contains(value) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected one of \(choices.map { "\"\($0)\"" }.joined(separator: ", "))")
        }
        return value
    }

    /// A date, or the first instant after one when `inclusiveEnd`: `to_date` is inclusive
    /// at the precision written, so a plain day covers that whole day and a time to the
    /// minute covers that whole minute. Returns the text as written too, for the result to
    /// say which range it holds.
    public func optionalDate(_ name: String, inclusiveEnd: Bool = false) throws
        -> (date: Date, written: String)?
    {
        guard let raw = try optionalString(name) else { return nil }
        let parsed = try DateParsing.parse(raw, argument: name, calendar: calendar)
        return (inclusiveEnd ? parsed.endExclusive(calendar: calendar) : parsed.date, raw)
    }
}
