#!/bin/bash -eu
# Build Whistle's Swift fuzz targets for ClusterFuzzLite / OSS-Fuzz.
#
# The fuzz targets live in the standalone `Fuzzing/` SwiftPM package so they
# never touch the app build or the `swift test` CI path.
#
# Flag construction mirrors OSS-Fuzz's swift-protobuf project. The key detail:
# use SwiftPM's *native* `--sanitize=fuzzer` (double-dash `swift build` flag),
# NOT `-Xswiftc -sanitize=fuzzer`. The native flag makes SwiftPM link each
# executable target as a libFuzzer binary and suppresses the `<target>_main`
# entry shim that otherwise collides with libFuzzer's own main().

. precompile_swift
cd "$SRC/whistle/Fuzzing"

export SWIFTFLAGS="-Xswiftc -static-stdlib --static-swift-stdlib"
if [ "$SANITIZER" = "coverage" ]; then
  export SWIFTFLAGS="$SWIFTFLAGS -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping --sanitize=fuzzer"
else
  export SWIFTFLAGS="$SWIFTFLAGS --sanitize=fuzzer --sanitize=$SANITIZER"
  for f in $CFLAGS; do export SWIFTFLAGS="$SWIFTFLAGS -Xcc=$f"; done
  for f in $CXXFLAGS; do export SWIFTFLAGS="$SWIFTFLAGS -Xcxx=$f"; done
fi

swift build -c debug $SWIFTFLAGS

cd .build/debug/
find . -maxdepth 1 -type f -name "Fuzz_*" -executable | while read -r bin; do
  cp "$bin" "$OUT/$(basename "$bin")"
done
