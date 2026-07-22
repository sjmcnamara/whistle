# ClusterFuzzLite build container for Whistle's Swift payload-parser fuzzers.
# Uses the OSS-Fuzz Swift base image, which ships the Swift toolchain plus the
# libFuzzer engine and sanitizer runtimes.
FROM gcr.io/oss-fuzz-base/base-builder-swift

COPY . $SRC/whistle
WORKDIR $SRC/whistle
# OSS-Fuzz's `compile` runs $SRC/build.sh by convention.
COPY .clusterfuzzlite/build.sh $SRC/
