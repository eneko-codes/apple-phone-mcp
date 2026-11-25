import Foundation
import Testing

@testable import PhoneMCPCore

/// The manifest is not documentation. Claude Desktop builds the per-tool permission
/// switches from its `tools` array, before this server has ever run, so a tool missing
/// from it has no switch and a tool listed there that no longer exists is a switch that
/// controls nothing. Nothing at runtime can detect either, which is why it is checked
/// here.
@Suite("Extension manifest")
struct ManifestTests {

    /// Derived from this file's own path: SwiftPM makes no promise about the working
    /// directory a test runs in, and these two files are deliberately outside the
    /// package's resources.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PhoneMCPCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryRoot.appending(path: "extension/manifest.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryRoot.appending(path: "Resources/Info.plist"))
        return try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] ?? [:]
    }

    private func declaredTools() throws -> [[String: Any]] {
        try manifest()["tools"] as? [[String: Any]] ?? []
    }

    @Test("Every tool the server exposes has a switch, and every switch has a tool")
    func manifestMatchesTheCatalogue() throws {
        let declared = Set(try declaredTools().compactMap { $0["name"] as? String })
        #expect(declared == Set(ToolCatalog.all().map(\.name)))
    }

    @Test("Every declared tool carries a description for its switch to be labelled with")
    func everyDeclaredToolIsDescribed() throws {
        for tool in try declaredTools() {
            let name = tool["name"] as? String ?? "(unnamed)"
            #expect((tool["description"] as? String)?.isEmpty == false, "\(name)")
        }
    }

    /// The manifest is plain JSON and cannot take the figure from the constant, so this
    /// holds the one bound it states to the one the code enforces.
    @Test("The manifest and the README state the deadline the server enforces")
    func prosStatesTheDeadline() throws {
        let seconds = PhoneTools.defaultTimeout.components.seconds
        let description = try #require(try manifest()["long_description"] as? String)
        #expect(description.contains("after \(seconds) seconds"))
        let readme = try String(
            contentsOf: Self.repositoryRoot.appending(path: "README.md"), encoding: .utf8)
        #expect(readme.replacingOccurrences(of: "\n", with: " ").contains("after \(seconds) seconds"))
    }

    /// The version is read by three different things — the extension installer, the
    /// `initialize` response, and the embedded Info.plist that TCC shows. Two of them
    /// disagreeing is how a bug report ends up describing a build nobody has.
    @Test("The version matches the server and the embedded Info.plist")
    func versionsAgree() throws {
        #expect(try manifest()["version"] as? String == PhoneMCPServer.version)
        #expect(try infoPlist()["CFBundleShortVersionString"] as? String == PhoneMCPServer.version)
    }

    /// Without it the Contacts request is denied silently, with no dialog and nothing
    /// logged, and every call is shown without a name.
    @Test("The Info.plist declares the Contacts usage description")
    func contactsUsageDescriptionIsDeclared() throws {
        #expect((try infoPlist()["NSContactsUsageDescription"] as? String)?.isEmpty == false)
    }

    @Test("The bundle identifier matches the server name")
    func bundleIdentifier() throws {
        #expect(
            try infoPlist()["CFBundleIdentifier"] as? String == "codes.eneko.\(PhoneMCPServer.name)")
    }

    /// The server is built from the system's own frameworks and nothing else. A dependency
    /// is a decision for the owner, so adding one has to break this test first.
    @Test("The package declares no third-party dependency")
    func noDependencies() throws {
        let package = try String(
            contentsOf: Self.repositoryRoot.appending(path: "Package.swift"), encoding: .utf8)
        #expect(!package.contains(".package("), "Package.swift declares a dependency")
        #expect(!package.contains(".product("))
    }
}
