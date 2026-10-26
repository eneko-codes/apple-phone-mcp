// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-phone-mcp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        //
        // SQLite is `import SQLite3` from the macOS SDK — the system library the call
        // history store is written with. No package dependency: a wrapper would add a few
        // thousand lines to audit in exchange for syntax.
        .target(
            name: "PhoneMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "apple-phone-mcp",
            dependencies: ["PhoneMCPCore"],
            // TCC identifies this binary by its own embedded Info.plist. Claude Desktop
            // spawns MCP servers through Contents/Helpers/disclaimer, which calls
            // responsibility_spawnattrs_setdisclaim, so the process is its own TCC
            // subject and cannot borrow the host app's usage descriptions. Without the
            // embedded plist macOS denies Contacts access without ever prompting.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "PhoneMCPCoreTests", dependencies: ["PhoneMCPCore"]),
    ]
)
