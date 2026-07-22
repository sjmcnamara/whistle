#!/bin/bash -eu
# Build Whistle's Swift fuzz targets for ClusterFuzzLite / OSS-Fuzz.
#
# WhistleCore is a small, Foundation-only Swift package, so rather than fight
# SwiftPM's executable-target-vs-libFuzzer main() conflict (an executable target
# emits a `<target>_main` shim that -parse-as-library suppresses; a library
# target won't link a binary; a main.swift file auto-promotes back to an
# executable target on tools >= 5.4), we compile each fuzzer directly with
# swiftc: all WhistleCore sources plus one harness, as a single module, linked
# into a libFuzzer executable via -sanitize=fuzzer. The harnesses therefore
# reference WhistleCore's public types WITHOUT an `import` (same module).

. precompile_swift

cd "$SRC/whistle"
CORE_SRCS=$(find WhistleCore/Sources/WhistleCore -name '*.swift')

if [ "${SANITIZER:-address}" = "coverage" ]; then
  SAN="-sanitize=fuzzer -profile-generate -profile-coverage-mapping"
else
  SAN="-sanitize=fuzzer,${SANITIZER:-address}"
fi

for target in InviteCode LocationPayload ChatPayload JoinRequest; do
  # shellcheck disable=SC2086
  swiftc \
    $SAN \
    -parse-as-library \
    -static-stdlib \
    -Xcc -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION \
    $CORE_SRCS \
    ".clusterfuzzlite/harnesses/Fuzz_${target}.swift" \
    -o "$OUT/Fuzz_${target}"
done

# Seed corpus: the deeply-nested-JSON crash that motivated JSONNestingGuard, so
# every run re-exercises the guard. 513 '[' bytes — the raw form for the three
# jsonString decoders, base64-wrapped for InviteCode (which base64-decodes
# first). Best-effort: skip if zip is unavailable rather than fail the build.
if command -v zip >/dev/null 2>&1; then
  SEED_DIR="$(mktemp -d)"
  printf '[%.0s' $(seq 1 513) > "$SEED_DIR/nested-raw"
  base64 -w0 "$SEED_DIR/nested-raw" > "$SEED_DIR/nested-b64" 2>/dev/null \
    || base64 "$SEED_DIR/nested-raw" | tr -d '\n' > "$SEED_DIR/nested-b64"
  for target in LocationPayload ChatPayload JoinRequest; do
    zip -qj "$OUT/Fuzz_${target}_seed_corpus.zip" "$SEED_DIR/nested-raw"
  done
  zip -qj "$OUT/Fuzz_InviteCode_seed_corpus.zip" "$SEED_DIR/nested-b64"
fi
