"""Build-time helper: vendor a locally-repackaged copy of the MarmotKit XCFramework.

MarmotKit (marmot-protocol/mdk, tagged marmotkit-v<version>) ships its XCFramework
as a GitHub Release asset, not a git-hosted SPM package -- see
MarmotKitBindings/Package.swift's header comment and upstream's
crates/marmot-uniffi/DISTRIBUTION.md.

Its XCFramework puts a bare `Headers/module.modulemap` at the root of each
platform slice. Xcode's current build engine stages EVERY binary target's
Headers into one shared `Build/Products/<config>/include/` directory per
build, not one per framework -- so when a second XCFramework does the same
thing (NostrSDK's `nostr_sdkFFI.xcframework` already does), both copies
collide on `include/module.modulemap` with "Multiple commands produce".
Known upstream Xcode/swift-build bug, unresolved as of Xcode 16.1:
https://github.com/swiftlang/swift-build/issues/1746

Renaming or nesting the modulemap inside the xcframework only trades that
error for a silent one: Clang's automatic module-map discovery only looks
for a file literally named "module.modulemap" directly at a header search
path ROOT, so a moved/renamed copy stops colliding but also stops being
found -- `#if canImport(marmot_uniffiFFI)` in the generated bindings then
just skips the import with no diagnostic, cascading into hundreds of
"cannot find X in scope" errors.

The actual fix -- proven already, by this same repo's own MDKBindings
(vendor/mdk-swift/Package.swift) -- is to not let the xcframework's
embedded Headers/module.modulemap be the thing Xcode discovers at all.
mdk-swift's own xcframework (Binary/mdk_uniffi.xcframework) ships NO
modulemap, just a bare header; the actual Clang module Swift imports
(`mdk_uniffiFFI`) is a completely ordinary SPM target
(Sources/mdk_uniffiFFI, publicHeadersPath: "include") that depends on the
binaryTarget for the compiled .a. Ordinary SPM targets compile their
public headers through Xcode's normal per-target header handling, never
through the shared XCFramework-header bucket, so two of them never collide.

This script mirrors that exactly for MarmotKit: strip module.modulemap out
of the vendored xcframework (leaving its header + .a untouched -- the
header is vestigial once the wrapper target exists, same as mdk-swift's own
xcframework keeps one), and MarmotKitBindings/Package.swift declares its
own `marmot_uniffiFFI` target (Sources/marmot_uniffiFFI, committed to the
repo, not vendored) with that same module name and a copy of the header.

Mirrors ci_use_local_mdk.py's vendor/mdk-swift pattern for the *binary*
half of this: the checked-in MarmotKitBindings/Package.swift stays "clean"
(remote url + checksum on MarmotKitFFI, matching what DISTRIBUTION.md tells
consumers to write) and build.sh patches it to a local `path:` pointing at
this script's stripped-down copy, then restores it -- same patch/restore
shape as ensure_local_mdk()/restore_local_changes() use for project.yml.

Run with --print-version to emit the pinned MarmotKit version (parallels
ci_use_local_mdk.py --print-revision).
"""
import hashlib
import pathlib
import re
import sys
import urllib.request
import zipfile

VERSION = "0.10.4"
BASE_URL = f"https://github.com/marmot-protocol/mdk/releases/download/marmotkit-v{VERSION}"
XCFRAMEWORK_ZIP_URL = f"{BASE_URL}/MarmotKitFFI-{VERSION}.xcframework.zip"
XCFRAMEWORK_ZIP_SHA256 = "9deeeed623ec8dc193cedb5501faa820b4abc7423c6b2b3ba58b631c8c25560f"

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR_DIR = REPO_ROOT / "vendor"
ZIP_PATH = VENDOR_DIR / f"MarmotKitFFI-{VERSION}.xcframework.zip"
XCFRAMEWORK_DIR = VENDOR_DIR / "MarmotKitFFI.xcframework"
PACKAGE_SWIFT_PATH = REPO_ROOT / "MarmotKitBindings" / "Package.swift"

BINARY_TARGET_PATTERN = re.compile(
    r'\.binaryTarget\(\s*'
    r'name:\s*"MarmotKitFFI",\s*'
    r'url:\s*"[^"]+",\s*'
    r'checksum:\s*"[^"]+"\s*'
    r'\)',
    re.DOTALL,
)
LOCAL_BINARY_TARGET = (
    '.binaryTarget(\n'
    '            name: "MarmotKitFFI",\n'
    '            path: "../vendor/MarmotKitFFI.xcframework"\n'
    '        )'
)


def sha256_of(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download_and_verify_zip():
    if ZIP_PATH.exists() and sha256_of(ZIP_PATH) == XCFRAMEWORK_ZIP_SHA256:
        return
    VENDOR_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {XCFRAMEWORK_ZIP_URL}...")
    urllib.request.urlretrieve(XCFRAMEWORK_ZIP_URL, ZIP_PATH)
    actual = sha256_of(ZIP_PATH)
    if actual != XCFRAMEWORK_ZIP_SHA256:
        ZIP_PATH.unlink()
        raise SystemExit(
            f"ERROR: MarmotKitFFI-{VERSION}.xcframework.zip checksum mismatch "
            f"(got {actual}, expected {XCFRAMEWORK_ZIP_SHA256})"
        )


def repackage_xcframework():
    if XCFRAMEWORK_DIR.exists():
        return
    with zipfile.ZipFile(ZIP_PATH) as zf:
        zf.extractall(VENDOR_DIR)
    extracted = VENDOR_DIR / "MarmotKit.xcframework"
    extracted.rename(XCFRAMEWORK_DIR)

    for modulemap in XCFRAMEWORK_DIR.glob("*/Headers/module.modulemap"):
        modulemap.unlink()


def patch_package_swift():
    original = PACKAGE_SWIFT_PATH.read_text()
    if not BINARY_TARGET_PATTERN.search(original):
        if 'path: "../vendor/MarmotKitFFI.xcframework"' in original:
            return None  # already patched
        raise SystemExit(
            "ERROR: MarmotKitBindings/Package.swift's MarmotKitFFI binaryTarget "
            "must use the 'url:'+'checksum:' form for this script to patch it."
        )
    patched = BINARY_TARGET_PATTERN.sub(LOCAL_BINARY_TARGET, original)
    PACKAGE_SWIFT_PATH.write_text(patched)
    return original


if __name__ == "__main__":
    if "--print-version" in sys.argv:
        print(VERSION)
        sys.exit(0)
    download_and_verify_zip()
    repackage_xcframework()
    patch_package_swift()
    print(f"MarmotKitBindings/Package.swift patched: MarmotKitFFI -> vendor/MarmotKitFFI.xcframework (pinned at {VERSION})")
