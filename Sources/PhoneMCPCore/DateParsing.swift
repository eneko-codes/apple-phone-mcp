import Foundation

/// How much of the clock the caller wrote. `to_date` is inclusive at that precision: a day
/// covers the whole day, a minute the whole minute, a second the whole second.
public enum DatePrecision: Sendable, Equatable {
    case day
    case minute
    case second
    case fraction
}

public struct ParsedDate: Sendable, Equatable {
    public let date: Date
    public let precision: DatePrecision

    public init(date: Date, precision: DatePrecision) {
        self.date = date
        self.precision = precision
    }

    /// The first instant after everything the caller's text names, which is where an
    /// inclusive end stops. A day is added on the calendar, not as 86 400 seconds, so a day
    /// with a clock change still ends at the next midnight.
    public func endExclusive(calendar: Calendar) -> Date {
        switch precision {
        case .day: calendar.date(byAdding: .day, value: 1, to: date) ?? date
        case .minute: date.addingTimeInterval(60)
        case .second: date.addingTimeInterval(1)
        case .fraction: date.addingTimeInterval(0.001)
        }
    }
}

/// Parsing and rendering of the three date forms this server accepts.
///
/// Deliberately strict. A lenient parser that guesses at `10/08/2026` will one day read
/// it as 8 October for a caller who meant 10 August, and a search that quietly answers
/// about the wrong two months is worse than one that refuses the input.
public enum DateParsing {

    public static let acceptedForms = """
        - 2026-08-12                  a whole day, local time
        - 2026-08-12T09:00            local time
        - 2026-08-12T09:00:00+02:00   explicit offset
        """

    public static func parse(_ raw: String, argument: String, calendar: Calendar) throws
        -> ParsedDate
    {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let components = dayComponents(text) {
            guard let day = existing(components, calendar: calendar) else {
                throw ToolError.badDate(argument: argument, value: text)
            }
            return ParsedDate(date: calendar.startOfDay(for: day), precision: .day)
        }

        if let (components, precision) = localComponents(text) {
            guard let moment = existing(components, calendar: calendar) else {
                throw ToolError.badDate(argument: argument, value: text)
            }
            return ParsedDate(date: moment, precision: precision)
        }

        // Only reached for a string carrying its own offset or Z suffix, where the
        // machine's time zone is irrelevant.
        let optionSets: [(ISO8601DateFormatter.Options, DatePrecision)] = [
            ([.withInternetDateTime], .second),
            ([.withInternetDateTime, .withFractionalSeconds], .fraction),
        ]
        for (options, precision) in optionSets {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let moment = formatter.date(from: text) {
                // The formatter moves 30 February to 2 March; the day is checked as written.
                guard let day = dayComponents(String(text.prefix(10))),
                    existing(day, calendar: utc) != nil
                else { throw ToolError.badDate(argument: argument, value: text) }
                return ParsedDate(date: moment, precision: precision)
            }
        }

        throw ToolError.badDate(argument: argument, value: text)
    }

    /// The date `components` name, or `nil` when no such moment exists: 30 February, or an
    /// hour a clock change skipped. `Calendar` would quietly move those to the next
    /// valid moment, so the result is read back and has to say what was written.
    private static func existing(_ components: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: components) else { return nil }
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let readBack = calendar.dateComponents(units, from: date)
        guard readBack.year == components.year, readBack.month == components.month,
            readBack.day == components.day,
            readBack.hour == (components.hour ?? 0),
            readBack.minute == (components.minute ?? 0),
            readBack.second == (components.second ?? 0)
        else { return nil }
        return date
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `YYYY-MM-DD` and nothing else.
    private static func dayComponents(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// `YYYY-MM-DDTHH:MM` or `YYYY-MM-DDTHH:MM:SS`, with no offset suffix, and how many of
    /// those pieces were written.
    private static func localComponents(_ text: String) -> (DateComponents, DatePrecision)? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2, var day = dayComponents(String(halves[0])) else { return nil }

        let time = halves[1]
        // A trailing Z or offset means the string is absolute; that is the ISO path.
        guard !time.contains("Z"), !time.contains("+"), time.filter({ $0 == "-" }).isEmpty
        else { return nil }

        let pieces = time.split(separator: ":")
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ $0.count == 2 }),
            let hour = Int(pieces[0]), let minute = Int(pieces[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        let second = pieces.count == 3 ? Int(pieces[2]) : 0
        guard let second, (0...59).contains(second) else { return nil }

        day.hour = hour
        day.minute = minute
        day.second = second
        return (day, pieces.count == 3 ? .second : .minute)
    }

    // MARK: Rendering

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Hand-rolled rather than `DateFormatter` so output does not change shape with the
    /// machine's locale. A model that has learned to read `Mon 10 Aug` should not be
    /// handed `lun 10 ago` on a differently configured Mac.
    public static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.weekday, .day, .month], from: date)
        let weekday = parts.weekday.map { weekdays[($0 - 1) % 7] } ?? "???"
        let month = parts.month.map { months[($0 - 1) % 12] } ?? "???"
        return String(format: "%@ %02d %@", weekday, parts.day ?? 0, month)
    }

    public static func dayWithYear(_ date: Date, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: date)
        return "\(day(date, calendar: calendar)) \(year)"
    }

    public static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `2026-08-12T09:00` — the form `from_date` and `to_date` accept, so a range this server
    /// echoes back can be pasted straight into the next call.
    public static func roundTrip(_ date: Date, dayOnly: Bool = false, calendar: Calendar) -> String
    {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard !dayOnly else { return day }
        return day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
