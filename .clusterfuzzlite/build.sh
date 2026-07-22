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
