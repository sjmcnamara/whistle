#!/bin/bash -eu
# Build Whistle's Swift fuzz targets for ClusterFuzzLite / OSS-Fuzz.
#
# The fuzz targets live in the standalone `Fuzzing/` SwiftPM package so they
# never touch the app build or the `swift test` CI path. Each is an executable
# with no main(); libFuzzer supplies main() via `-sanitize=fuzzer`, hence
# `-parse-as-library`. $SANITIZER is set by the OSS-Fuzz infra (address by
# default; coverage builds skip the sanitizer runtime).

cd "$SRC/whistle/Fuzzing"

SANITIZER_FLAG="-sanitize=fuzzer,${SANITIZER:-address}"
if [ "${SANITIZER:-}" = "coverage" ]; then
  # Coverage builds instrument for libFuzzer but must not link a sanitizer rt.
  SANITIZER_FLAG="-sanitize=fuzzer"
fi

swift build -c debug \
  -Xswiftc "$SANITIZER_FLAG" \
  -Xswiftc -parse-as-library

BIN_DIR="$(swift build -c debug --show-bin-path)"
for target in Fuzz_InviteCode Fuzz_LocationPayload Fuzz_ChatPayload Fuzz_JoinRequest; do
  cp "$BIN_DIR/$target" "$OUT/$target"
done
