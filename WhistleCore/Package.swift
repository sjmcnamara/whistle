// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhistleCore",
    platforms: [
        .iOS(.v17),
        // The package is only ever shipped in the iOS app, but its tests run
        // via `swift test` on macOS in CI. Without a macOS floor that build
        // targets an ancient default (pre-10.15), where APIs like
        // JSONEncoder's `.withoutEscapingSlashes` are unavailable — which is
        // needed so relay URLs are not slash-escaped, matching Android's
        // org.json output so the two platforms' diagnostics reports diff.
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "WhistleCore",
            targets: ["WhistleCore"]
        )
    ],
    targets: [
        .target(
            name: "WhistleCore",
            path: "Sources/WhistleCore"
        ),
        .testTarget(
            name: "WhistleCoreTests",
            dependencies: ["WhistleCore"],
            path: "Tests/WhistleCoreTests"
        )
    ]
)
