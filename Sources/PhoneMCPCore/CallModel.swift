import Foundation

/// Whether the call history database can be opened at all.
///
/// `~/Library/Application Support/CallHistoryDB` sits behind Full Disk Access, which —
/// unlike Contacts — has no usage-description key and no API to request it. A process
/// can only try, fail, and explain. That is why this is a plain enum rather than an
/// authorisation status with a `request` counterpart.
public enum DatabaseAccess: Sendable, Equatable {
    case granted
    /// `open(2)` refused with EPERM or EACCES, or SQLite reported SQLITE_AUTH. On the real
    /// path that means Full Disk Access has not been granted to this binary.
    case denied
    case missing(path: String)
    case failed(String)

    public var isUsable: Bool { self == .granted }
}

/// Mirrors `CNAuthorizationStatus`, minus the iOS-only `.limited` case.
public enum ContactsAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized

    public var isUsable: Bool { self == .authorized }
}

/// Derived from two columns, because the store has no direction column of its own.
///
/// `ZORIGINATED` says who placed the call; `ZANSWERED` says whether it was picked up.
/// "Missed" is an inference — incoming and not answered — not a stored fact. A declined
/// call and one that rang out look the same.
public enum CallDirection: String, Sendable, Equatable, CaseIterable {
    case incoming
    case outgoing
    case missed

    static func from(originated: Bool, answered: Bool) -> CallDirection {
        if originated { return .outgoing }
        return answered ? .incoming : .missed
    }
}

/// `ZCALLTYPE`. Values outside the three known ones are kept, not guessed at, so a new
/// kind of call shows up as a number rather than disappearing into "phone".
public enum CallKind: Sendable, Equatable {
    case phone
    case facetimeVideo
    case facetimeAudio
    case other(Int64)

    static let phoneRawValue: Int64 = 1
    static let facetimeVideoRawValue: Int64 = 8
    static let facetimeAudioRawValue: Int64 = 16

    init(rawValue: Int64) {
        switch rawValue {
        case Self.phoneRawValue: self = .phone
        case Self.facetimeVideoRawValue: self = .facetimeVideo
        case Self.facetimeAudioRawValue: self = .facetimeAudio
        default: self = .other(rawValue)
        }
    }

    var rawValue: Int64 {
        switch self {
        case .phone: Self.phoneRawValue
        case .facetimeVideo: Self.facetimeVideoRawValue
        case .facetimeAudio: Self.facetimeAudioRawValue
        case .other(let value): value
        }
    }

    /// The spelling the `kind` argument accepts, so a value read from a result can be
    /// passed straight back as a filter.
    public var label: String {
        switch self {
        case .phone: "phone"
        case .facetimeVideo: "facetime_video"
        case .facetimeAudio: "facetime_audio"
        case .other(let value): "other(\(value))"
        }
    }

    static let filterable: [CallKind] = [.phone, .facetimeAudio, .facetimeVideo]
}

public struct CallRecord: Sendable, Equatable {
    /// `ZCALLRECORD.Z_PK`. Local to this database: the system can rebuild the store and
    /// renumber it, so an id is only good within one conversation.
    public let id: Int64
    public let uniqueID: String?
    public let date: Date
    /// Seconds. Zero for a call that never connected.
    public let duration: TimeInterval
    public let direction: CallDirection
    /// `nil` for outgoing calls: the store leaves `ZANSWERED` at 0 on every outgoing call
    /// whether or not the other side picked up, so reporting it would be a false "no".
    public let answered: Bool?
    public let kind: CallKind
    /// `ZSERVICE_PROVIDER`, e.g. `com.apple.Telephony` or `com.apple.FaceTime`.
    public let serviceProvider: String?
    /// The other party's numbers or Apple Account addresses, exactly as stored. More than
    /// one for a group FaceTime call.
    public let remoteAddresses: [String]
    /// `ZNAME`: the name the system cached at call time. Usually empty.
    public let storedName: String?
    public let countryCode: String?
    /// `ZDISCONNECTED_CAUSE`, undecoded — its values are not documented anywhere.
    public let disconnectedCause: Int64?

    public init(
        id: Int64, uniqueID: String?, date: Date, duration: TimeInterval,
        direction: CallDirection, answered: Bool?, kind: CallKind, serviceProvider: String?,
        remoteAddresses: [String], storedName: String?, countryCode: String?,
        disconnectedCause: Int64?
    ) {
        self.id = id
        self.uniqueID = uniqueID
        self.date = date
        self.duration = duration
        self.direction = direction
        self.answered = answered
        self.kind = kind
        self.serviceProvider = serviceProvider
        self.remoteAddresses = remoteAddresses
        self.storedName = storedName
        self.countryCode = countryCode
        self.disconnectedCause = disconnectedCause
    }
}

/// Every field is optional; the ones that are set combine with AND.
public struct CallFilter: Sendable, Equatable {
    public var from: Date?
    /// Exclusive.
    public var to: Date?
    public var direction: CallDirection?
    public var kind: CallKind?
    /// Calls with any remote address in this set, compared with `AddressKey`.
    public var addresses: Set<AddressKey>?

    public init() {}
}

public struct CallPage: Sendable, Equatable {
    public let calls: [CallRecord]
    /// Matches across the whole history, not just this page.
    public let total: Int

    public init(calls: [CallRecord], total: Int) {
        self.calls = calls
        self.total = total
    }
}

public struct StoreStatus: Sendable, Equatable {
    public let access: DatabaseAccess
    public let databasePath: String
    public let callCount: Int?
    public let oldestCall: Date?
    public let newestCall: Date?
    /// Columns this server would use if present and has replaced with NULL instead.
    public let missingOptionalColumns: [String]
    /// Size of the write-ahead log. This server reads through it, so these are calls it
    /// can see that are not yet in the main file.
    public let walBytes: Int64?

    public init(
        access: DatabaseAccess, databasePath: String, callCount: Int? = nil,
        oldestCall: Date? = nil, newestCall: Date? = nil, missingOptionalColumns: [String] = [],
        walBytes: Int64? = nil
    ) {
        self.access = access
        self.databasePath = databasePath
        self.callCount = callCount
        self.oldestCall = oldestCall
        self.newestCall = newestCall
        self.missingOptionalColumns = missingOptionalColumns
        self.walBytes = walBytes
    }
}

/// A comparable form of a phone number or Apple Account address.
///
/// The store keeps a number however the network delivered it — `+12125550104` on one
/// call, `2125550104` on another — and Contacts keeps it however it was typed. Comparing
/// on the last nine digits makes those the same number without inferring a country code.
/// The cost, stated: two numbers from different countries that share their last nine
/// digits compare equal. Numbers shorter than seven digits (short codes, voicemail) are
/// compared whole. Anything with an `@` is an email, compared case-insensitively.
public struct AddressKey: Sendable, Hashable {
    static let significantDigits = 9
    static let minimumPhoneDigits = 7

    let value: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("@") {
            value = trimmed.lowercased()
            return
        }
        let digits = trimmed.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        value =
            digits.count >= Self.minimumPhoneDigits
            ? String(digits.suffix(Self.significantDigits)) : digits
    }
}
