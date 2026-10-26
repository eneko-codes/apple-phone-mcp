import Foundation

/// Fixed limits. Plug and play: nothing here is a setting the person installing the
/// extension can change; only the per-tool allow/ask/prohibit switch in Claude Desktop
/// controls this server.
public enum Configuration {

    /// Default page size for `calls_list`. A tool's own `limit` still wins.
    public static let listLimit = 50

    public static let listLimitRange = 1...200

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...100_000
}
