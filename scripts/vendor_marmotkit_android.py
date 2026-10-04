#!/usr/bin/env python3
"""Vendor MarmotKit's Android native library into the Gradle build.

Mirrors `vendor_marmotkit.py` (iOS) in shape and conventions, with one
deliberate difference: only the `.so` is vendored. The generated Kotlin
bindings are checked in, exactly as `MarmotKit.swift` is on the iOS side,
because they are reviewable source and a version bump should show up as a
readable diff.

Why vendor the binary at all, when MDK's `libmdk_uniffi.so` is committed?
Because MarmotKit's is 51.8MB for arm64 alone — already stripped, so there is
no slimming it — against MDK's 15.6MB. Committing it would add that to the
repository permanently on every version bump. The iOS side already vendors its
XCFramework for the same reason, and `build.sh`/CI already know the pattern.

**arm64-v8a only.** Agreed deliberately: the four published ABIs total 218MB,
and shipping the three the app previously carried would take the APK from 89MB
to roughly 200MB+ for a download hosted on the website and Zapstore. `minSdk`
is 26 (Android 8.0, 2017), by which point 64-bit ARM was universal, and CI runs
no emulator so x86_64 earns nothing there. The trade-off is that pre-2015
32-bit ARM devices and x86 emulators are no longer supported.
"""

import argparse
import hashlib
import pathlib
import shutil
import sys
import urllib.request
import zipfile

VERSION = "0.10.4"
BASE_URL = f"https://github.com/marmot-protocol/mdk/releases/download/marmotkit-v{VERSION}"
ANDROID_ZIP_URL = f"{BASE_URL}/marmotkit-android-{VERSION}.zip"
ANDROID_ZIP_SHA256 = "dcbb4e00c703cce2cf773c860f1f1d46b18ac49e81af5a5089902b8a31e0c16e"

# The one ABI we ship. See the module docstring for why.
ABI = "arm64-v8a"
SO_NAME = "libmarmot_uniffi.so"

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR_DIR = REPO_ROOT / "vendor"
ZIP_PATH = VENDOR_DIR / f"marmotkit-android-{VERSION}.zip"
JNI_LIBS_DIR = REPO_ROOT / "android" / "app" / "src" / "main" / "jniLibs" / ABI
SO_PATH = JNI_LIBS_DIR / SO_NAME

ARCHIVE_ROOT = f"marmotkit-android-{VERSION}"
ARCHIVE_SO = f"{ARCHIVE_ROOT}/jniLibs/{ABI}/{SO_NAME}"


def sha256_of(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download_and_verify_zip():
    if ZIP_PATH.exists() and sha256_of(ZIP_PATH) == ANDROID_ZIP_SHA256:
        return
    VENDOR_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {ANDROID_ZIP_URL}...")
    urllib.request.urlretrieve(ANDROID_ZIP_URL, ZIP_PATH)
    actual = sha256_of(ZIP_PATH)
    if actual != ANDROID_ZIP_SHA256:
        # Removed so a retry re-downloads rather than failing on the same bad
        # bytes forever.
        ZIP_PATH.unlink()
        raise SystemExit(
            f"ERROR: marmotkit-android-{VERSION}.zip checksum mismatch "
            f"(got {actual}, expected {ANDROID_ZIP_SHA256})"
        )


def extract_native_library():
    """Place the single ABI's `.so` where the Android Gradle plugin expects it."""
    if SO_PATH.exists():
        print(f"{SO_PATH.relative_to(REPO_ROOT)} already present")
        return

    JNI_LIBS_DIR.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ZIP_PATH) as archive:
        names = set(archive.namelist())
        if ARCHIVE_SO not in names:
            available = sorted(n for n in names if n.endswith(".so"))
            raise SystemExit(
                f"ERROR: {ARCHIVE_SO} not in the archive. Available: {available}"
            )
        with archive.open(ARCHIVE_SO) as source, SO_PATH.open("wb") as target:
            shutil.copyfileobj(source, target)

    size_mb = SO_PATH.stat().st_size / (1 << 20)
    print(f"Extracted {SO_NAME} ({ABI}, {size_mb:.1f}MB)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--print-version",
        action="store_true",
        help="Print the pinned MarmotKit version and exit (used for CI cache keys).",
    )
    args = parser.parse_args()

    if args.print_version:
        print(VERSION)
        return

    download_and_verify_zip()
    extract_native_library()


if __name__ == "__main__":
    sys.exit(main())
