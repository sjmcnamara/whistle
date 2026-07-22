#!/bin/bash -eu
# Build Whistle's Swift fuzz targets for ClusterFuzzLite / OSS-Fuzz.
#
# The fuzz targets live in the standalone `Fuzzing/` SwiftPM package so they
# never touch the app build or the `swift test` CI path.
#
# Recipe mirrors OSS-Fuzz's swift-nio project, which targets this same
# base-builder-swift image: source `precompile_swift` (it exports the correct
# $SWIFTFLAGS for the image's toolchain — including -sanitize=fuzzer and
# -parse-as-library) and build with `swift build $SWIFTFLAGS`. Each fuzz
# target's entry file must be named `main.swift` so SwiftPM emits the
# `<target>_main` symbol its executable-product main shim links against.

. precompile_swift
cd "$SRC/whistle/Fuzzing"

swift build -c debug $SWIFTFLAGS

cd .build/debug/
find . -maxdepth 1 -type f -name "Fuzz_*" -executable | while read -r bin; do
  cp "$bin" "$OUT/$(basename "$bin")"
done
