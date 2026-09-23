// swift-tools-version: 6.0
import PackageDescription

// MDK 2.0 / MarmotKit spike (see ROADMAP.md "Deferred" section and CLAUDE.md's
// MDK dependency notes). MarmotKit has no git-hosted SPM package — it publishes
// its XCFramework, generated Swift, and privacy manifest as GitHub Release
// assets under marmot-protocol/mdk, tagged `marmotkit-v<version>`. Consumers
// are expected to hand-author this wrapper. See:
// https://github.com/marmot-protocol/mdk/blob/v0.10.4/crates/marmot-uniffi/DISTRIBUTION.md
//
// MarmotKitFFI-0.10.4.xcframework.zip requires iOS 18.0+ (DISTRIBUTION.md,
// "SwiftPM" section) — this is why Whistle's own deploymentTarget moved to 18.0
// alongside this package.
//
// MarmotKitFFI's own xcframework ships a bare `Headers/module.modulemap` —
// consuming it directly collides with NostrSDK's own xcframework-embedded
// modulemap in Xcode's shared per-build `include/` directory (a known,
// unresolved Xcode/swift-build bug: swiftlang/swift-build#1746). This repo's
// own MDKBindings (vendor/mdk-swift/Package.swift) already avoids that same
// problem for mdk_uniffiFFI.xcframework by never letting Xcode discover the
// xcframework's own modulemap at all: the binaryTarget is depended on by an
// ordinary SPM target (`marmot_uniffiFFI` below) that declares its own
// `publicHeadersPath` and modulemap, which Xcode compiles through the normal
// per-target header path instead of the colliding shared bucket. Mirrored
// exactly here — see scripts/vendor_marmotkit.py for how the vendored copy of
// the xcframework gets its own embedded modulemap stripped to match.

let package = Package(
    name: "MarmotKitBindings",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "MarmotKit",
            targets: ["MarmotKit"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "MarmotKitFFI",
            url: "https://github.com/marmot-protocol/mdk/releases/download/marmotkit-v0.10.4/MarmotKitFFI-0.10.4.xcframework.zip",
            checksum: "9deeeed623ec8dc193cedb5501faa820b4abc7423c6b2b3ba58b631c8c25560f"
        ),
        .target(
            name: "marmot_uniffiFFI",
            dependencies: ["MarmotKitFFI"],
            path: "Sources/marmot_uniffiFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MarmotKit",
            dependencies: ["marmot_uniffiFFI"],
            path: "Sources/MarmotKit",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS]))
            ]
        )
    ],
    // Tools-version 6.0 defaults to Swift 6 language mode; the generated
    // MarmotKit.swift is upstream-vendored and untouched, so stay on 5 to
    // avoid taking on strict-concurrency fallout from a file we don't own.
    swiftLanguageModes: [.v5]
)
