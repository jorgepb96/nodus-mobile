// swift-tools-version: 6.0
import PackageDescription

// NodusKit is the whole conversation with a Nodus Server: the typed client, the models the
// server actually publishes, the Keychain, and the offline mirror.
//
// It builds for macOS as well as iOS on purpose. Every rule that is easy to get wrong — the
// envelope key that does not match the path, the ETag that includes the query string, a 409
// that means "not published yet" rather than an error — is covered by tests that run with
// `swift test`, with no simulator and no Xcode in the way.
let package = Package(
    name: "NodusKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NodusKit", targets: ["NodusKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "NodusKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // GRDB is here as well as in the target above so a test can write a database in the
        // shape an *older* build of the app left behind, and then watch the migration open it.
        // Nothing else can prove that a queue already on somebody's phone survives an upgrade.
        .testTarget(
            name: "NodusKitTests",
            dependencies: [
                "NodusKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
