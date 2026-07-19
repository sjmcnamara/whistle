#!/usr/bin/env bash
set -euo pipefail

# Famstr build script
# Usage:
#   ./scripts/build.sh              # generate + build
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

ensure_local_mdk() {
    local revision
    revision=$(python3 scripts/ci_use_local_mdk.py --print-revision)
    if [ ! -d "vendor/mdk-swift" ]; then
        echo "▸ Cloning mdk-swift at $revision (LFS)..."
        git clone https://github.com/marmot-protocol/mdk-swift.git vendor/mdk-swift
        (cd vendor/mdk-swift && git checkout "$revision" && git lfs pull)
    fi
    python3 scripts/ci_use_local_mdk.py
}

restore_local_changes() {
    git checkout -- project.yml 2>/dev/null || true
}

case "$COMMAND" in
    build)
        echo "▸ Generating Xcode project..."
        ensure_local_mdk
        xcodegen generate
        restore_local_changes

        echo "▸ Building $SCHEME..."
        xcodebuild build \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "$DESTINATION" \
            -quiet \
            CODE_SIGNING_ALLOWED=NO

        echo "✓ Build succeeded"
        ;;

    test)
        # mdk-swift only ships arm64 slices. On Intel Macs the simulator
        # needs x86_64-apple-ios which requires building MDK from Rust source.
        # Use CI (macos-15 arm64 runner) for the full test suite instead.
        if [[ "$(uname -m)" == "x86_64" ]]; then
            echo "⚠️  Intel Mac detected — mdk-swift has no x86_64 simulator slice."
            echo "   Local simulator tests will fail with missing symbols."
            echo "   Push to CI (arm64 runner) to run the full test suite."
            echo "   Use './scripts/build.sh' (no 'test') to build and test manually in Xcode."
            exit 1
        fi

        echo "▸ Generating Xcode project..."
        ensure_local_mdk
        xcodegen generate
        restore_local_changes

        echo "▸ Testing $SCHEME..."
        xcodebuild test \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "$DESTINATION" \
            CODE_SIGNING_ALLOWED=NO

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
        echo "Usage: $0 [build|test|clean]"
        exit 1
        ;;
esac
