// swift-tools-version: 5.9
import PackageDescription

// Separate package so the fuzz executables (which must link the libFuzzer
// engine via `-sanitize=fuzzer`) never enter the main WhistleCore build or the
// `swift test` CI path. `.clusterfuzzlite/build.sh` builds this package on the
// OSS-Fuzz Swift toolchain via precompile_swift + swift build $SWIFTFLAGS; see
// .clusterfuzzlite/README.md.
//
// Each target's entry file is main.swift (required so SwiftPM's
// executable-product main shim resolves the target_main symbol); it defines
// @_cdecl("LLVMFuzzerTestOneInput") and libFuzzer drives it.
let package = Package(
    name: "WhistleFuzzing",
    // Match WhistleCore's floor so local `swift build` on macOS links; ignored
    // on the Linux OSS-Fuzz toolchain where the fuzzers actually run.
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "Fuzz_InviteCode", targets: ["Fuzz_InviteCode"]),
        .executable(name: "Fuzz_LocationPayload", targets: ["Fuzz_LocationPayload"]),
        .executable(name: "Fuzz_ChatPayload", targets: ["Fuzz_ChatPayload"]),
        .executable(name: "Fuzz_JoinRequest", targets: ["Fuzz_JoinRequest"]),
    ],
    dependencies: [
        .package(path: "../WhistleCore")
    ],
    targets: [
        .executableTarget(name: "Fuzz_InviteCode",
                          dependencies: [.product(name: "WhistleCore", package: "WhistleCore")]),
        .executableTarget(name: "Fuzz_LocationPayload",
                          dependencies: [.product(name: "WhistleCore", package: "WhistleCore")]),
        .executableTarget(name: "Fuzz_ChatPayload",
                          dependencies: [.product(name: "WhistleCore", package: "WhistleCore")]),
        .executableTarget(name: "Fuzz_JoinRequest",
                          dependencies: [.product(name: "WhistleCore", package: "WhistleCore")]),
    ]
)
