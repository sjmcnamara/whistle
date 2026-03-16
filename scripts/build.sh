#!/usr/bin/env bash
set -euo pipefail

# Famstr build script
# Usage:
#   ./scripts/build.sh              # generate + build
#   ./scripts/build.sh test         # generate + build + test
#   ./scripts/build.sh clean        # clean build artifacts

COMMAND=${1:-build}
PROJECT="FindMyFam.xcodeproj"
SCHEME="FindMyFam"

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

SIMULATOR=$(detect_simulator)
echo "▸ Simulator: $SIMULATOR"
DESTINATION="platform=iOS Simulator,name=$SIMULATOR"

case "$COMMAND" in
    build)
        echo "▸ Generating Xcode project..."
        xcodegen generate

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
        echo "▸ Generating Xcode project..."
        xcodegen generate

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
        rm -rf ~/Library/Developer/Xcode/DerivedData/FindMyFam-* 2>/dev/null || true
        echo "✓ Clean complete"
        ;;

    *)
        echo "Usage: $0 [build|test|clean]"
        exit 1
        ;;
esac
