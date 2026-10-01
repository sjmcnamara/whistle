#!/usr/bin/env bash
set -euo pipefail

# Famstr build script
# Usage:
#   ./scripts/build.sh              # generate + build
#   ./scripts/build.sh compile-tests # type-check the test target (no run)
#   ./scripts/build.sh test         # generate + build + test
#   ./scripts/build.sh clean        # clean build artifacts

COMMAND=${1:-build}
PROJECT="Whistle.xcodeproj"
SCHEME="Whistle"

detect_simulator() {
    # Prefer the newest available iPhone simulator
    xcrun simctl list devices available --json 2>/dev/null \
        | python3 -c "
import json, sys, re

data = json.load(sys.stdin)
best_name = None
best_os   = (0, 0)

for runtime, devs in data.get('devices', {}).items():
    if 'iOS' not in runtime and 'iphonesimulator' not in runtime.lower():
        continue
    m = re.search(r'(\d+)[\.-](\d+)', runtime)
    os_ver = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    for d in devs:
        if d.get('isAvailable') and 'iPhone' in d.get('name', '') and 'iPad' not in d['name']:
            if os_ver > best_os:
                best_os   = os_ver
                best_name = d['name']

print(best_name or 'iPhone 16 Pro')
" 2>/dev/null || echo "iPhone 16 Pro"
}

if [[ "$(uname -m)" == "x86_64" ]]; then
    # mdk-swift has no x86_64-simulator slice — build for generic device (arm64) instead.
    echo "▸ Intel Mac detected — building for generic device (no x86_64 simulator slice in mdk-swift)"
    DESTINATION="generic/platform=iOS"
else
    SIMULATOR=$(detect_simulator)
    echo "▸ Simulator: $SIMULATOR"
    DESTINATION="platform=iOS Simulator,name=$SIMULATOR"
fi

# Snapshot of project.yml taken immediately before ci_use_local_mdk.py rewrites
# it to point at vendor/mdk-swift. Restored verbatim afterwards.
PROJECT_YML_BACKUP=""

# Same idea for MarmotKitBindings/Package.swift and vendor_marmotkit.py — see
# that script's header comment for why (swift-build#1746 module.modulemap
# collision between MarmotKitFFI and NostrSDK's nostr_sdkFFI).
MARMOTKIT_PACKAGE_SWIFT_BACKUP=""

ensure_local_mdk() {
    local revision
    revision=$(python3 scripts/ci_use_local_mdk.py --print-revision)
    if [ ! -d "vendor/mdk-swift" ]; then
        echo "▸ Cloning mdk-swift at $revision (LFS)..."
        git clone https://github.com/marmot-protocol/mdk-swift.git vendor/mdk-swift
        (cd vendor/mdk-swift && git checkout "$revision" && git lfs pull)
    fi
    PROJECT_YML_BACKUP=$(mktemp)
    cp project.yml "$PROJECT_YML_BACKUP"
    python3 scripts/ci_use_local_mdk.py
}

ensure_local_marmotkit() {
    MARMOTKIT_PACKAGE_SWIFT_BACKUP=$(mktemp)
    cp MarmotKitBindings/Package.swift "$MARMOTKIT_PACKAGE_SWIFT_BACKUP"
    python3 scripts/vendor_marmotkit.py
}

# Undo only the local-MDK patch. Restores the exact bytes we saw before
# patching, so uncommitted edits (e.g. a MARKETING_VERSION bump) survive —
# a `git checkout --` here would silently discard them. Safe to call right
# after `xcodegen generate`: xcodegen has already baked project.yml's package
# reference into the .xcodeproj, so project.yml's on-disk content stops
# mattering at that point.
restore_local_changes() {
    if [ -n "$PROJECT_YML_BACKUP" ] && [ -f "$PROJECT_YML_BACKUP" ]; then
        cp "$PROJECT_YML_BACKUP" project.yml
        rm -f "$PROJECT_YML_BACKUP"
        PROJECT_YML_BACKUP=""
    fi
}

# Undo the local-MarmotKit patch. Unlike project.yml, MarmotKitBindings is a
# local SPM package referenced BY PATH — xcodegen only records that path in
# the .xcodeproj, it does not bake in the package's own Package.swift
# contents. SwiftPM re-reads Package.swift from disk during xcodebuild's own
# package-resolution step, so this must stay patched until AFTER xcodebuild
# runs (never call this right after `xcodegen generate` the way
# restore_local_changes is called — that would restore the remote
# url+checksum binaryTarget before SwiftPM ever resolves the local one).
restore_marmotkit_changes() {
    if [ -n "$MARMOTKIT_PACKAGE_SWIFT_BACKUP" ] && [ -f "$MARMOTKIT_PACKAGE_SWIFT_BACKUP" ]; then
        cp "$MARMOTKIT_PACKAGE_SWIFT_BACKUP" MarmotKitBindings/Package.swift
        rm -f "$MARMOTKIT_PACKAGE_SWIFT_BACKUP"
        MARMOTKIT_PACKAGE_SWIFT_BACKUP=""
    fi
}

# `set -e` means a failing xcodegen/xcodebuild would otherwise leave
# project.yml/Package.swift pointing at the vendored copies.
trap 'restore_local_changes; restore_marmotkit_changes' EXIT

case "$COMMAND" in
    build)
        echo "▸ Generating Xcode project..."
        ensure_local_mdk
        ensure_local_marmotkit
        xcodegen generate
        restore_local_changes

        echo "▸ Building $SCHEME..."
        xcodebuild build \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "$DESTINATION" \
            -quiet \
            CODE_SIGNING_ALLOWED=NO

        restore_marmotkit_changes
        echo "✓ Build succeeded"
        ;;

    compile-tests)
        # Type-check the test target without running it.
        #
        # Intel Macs cannot *run* the suite (mdk-swift ships no x86_64 simulator
        # slice), but they can compile it for a generic arm64 device — which
        # catches the whole class of failure where WhistleTests stops compiling
        # and a plain `build.sh` still passes, because that only builds the app
        # target. Cheaper than discovering it in CI.
        echo "▸ Generating Xcode project..."
        ensure_local_mdk
        ensure_local_marmotkit
        xcodegen generate
        restore_local_changes

        echo "▸ Compiling $SCHEME test target..."
        xcodebuild build-for-testing \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination 'generic/platform=iOS' \
            -quiet \
            CODE_SIGNING_ALLOWED=NO

        restore_marmotkit_changes
        echo "✓ Test target compiles (not run — use CI or an arm64 Mac to execute)"
        ;;

    test)
        # mdk-swift only ships arm64 slices. On Intel Macs the simulator
        # needs x86_64-apple-ios which requires building MDK from Rust source.
        # Use CI (macos-15 arm64 runner) for the full test suite instead.
        if [[ "$(uname -m)" == "x86_64" ]]; then
            echo "⚠️  Intel Mac detected — mdk-swift has no x86_64 simulator slice."
            echo "   Local simulator tests will fail with missing symbols."
            echo "   Push to CI (arm64 runner) to run the full test suite."
            echo "   Use './scripts/build.sh compile-tests' to at least type-check the suite."
            exit 1
        fi

        echo "▸ Generating Xcode project..."
        ensure_local_mdk
        ensure_local_marmotkit
        xcodegen generate
        restore_local_changes

        echo "▸ Testing $SCHEME..."
        xcodebuild test \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "$DESTINATION" \
            CODE_SIGNING_ALLOWED=NO

        restore_marmotkit_changes
        echo "✓ Tests passed"
        ;;

    clean)
        echo "▸ Cleaning..."
        xcodebuild clean \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -quiet 2>/dev/null || true
        rm -rf ~/Library/Developer/Xcode/DerivedData/Whistle-* 2>/dev/null || true
        echo "✓ Clean complete"
        ;;

    *)
        echo "Usage: $0 [build|compile-tests|test|clean]"
        exit 1
        ;;
esac
