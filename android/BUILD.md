# Famstr Android — Build Guide

## Prerequisites

- **Android SDK** 35+ with build-tools 34+
- **Java 17** (Zulu or OpenJDK)
- **Rust** (via rustup) — only needed to rebuild MDK native libs

## Quick Build

```bash
cd android
./gradlew assembleDebug
```

APK output: `app/build/outputs/apk/debug/app-debug.apk`

## Install on Device

```bash
# USB-connected device
adb install app/build/outputs/apk/debug/app-debug.apk

# Specific device (if multiple connected)
adb -s <serial> install app/build/outputs/apk/debug/app-debug.apk
```

## Release Build

```bash
./gradlew assembleRelease
```

> Note: Release builds require signing config. Add to `android/app/build.gradle.kts` or use Android Studio's signing wizard.

## Configuration

Create `android/local.properties`:

```properties
sdk.dir=/path/to/Android/sdk
```

## Rebuilding MDK Native Libraries

The pre-built `.so` files in `app/src/main/jniLibs/` are checked into the repo.
To rebuild from source:

```bash
# Install Rust Android targets
rustup target add aarch64-linux-android x86_64-linux-android

# Clone MDK
git clone https://github.com/marmot-protocol/mdk.git /tmp/mdk-build

# Switch SQLCipher to plain bundled SQLite
sed -i 's/bundled-sqlcipher/bundled/' /tmp/mdk-build/crates/mdk-sqlite-storage/Cargo.toml

# Set NDK env vars (adjust NDK version as needed)
export ANDROID_NDK_HOME=$ANDROID_SDK/ndk/26.1.10909125
export CC_aarch64_linux_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang"
export CXX_aarch64_linux_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang++"
export AR_aarch64_linux_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-ar"
export CC_x86_64_linux_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/x86_64-linux-android24-clang"
export CXX_x86_64_linux_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/x86_64-linux-android24-clang++"
export AR_x86_64_linux_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-ar"

# Build for both targets
cd /tmp/mdk-build
cargo build --release -p mdk-uniffi --target aarch64-linux-android
cargo build --release -p mdk-uniffi --target x86_64-linux-android

# Copy .so files
cp target/aarch64-linux-android/release/libmdk_uniffi.so android/app/src/main/jniLibs/arm64-v8a/
cp target/x86_64-linux-android/release/libmdk_uniffi.so android/app/src/main/jniLibs/x86_64/

# Regenerate Kotlin bindings
cargo build --release -p mdk-uniffi  # host build for bindgen
cargo run --release -p mdk-uniffi --bin uniffi-bindgen generate \
    --library target/release/libmdk_uniffi.dylib \
    --language kotlin \
    --out-dir /tmp/mdk-kotlin
cp /tmp/mdk-kotlin/build/marmot/mdk/mdk_uniffi.kt android/app/src/main/java/build/marmot/mdk/
```

## Version Info

Version is set in `android/app/build.gradle.kts`:

```kotlin
versionCode = 1
versionName = "0.8.3"
```
