#!/usr/bin/env bash
# Build the Rust cdylib for all configured Android ABIs and drop the .so files into
# android/app/src/main/jniLibs/<abi>/ so Gradle picks them up.
#
# Usage:
#   ./scripts/build_rust_android.sh           # release
#   ./scripts/build_rust_android.sh --debug   # debug
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/rust"

PROFILE_FLAG="--release"
PROFILE_DIR="release"
if [ "${1:-}" = "--debug" ]; then
    PROFILE_FLAG=""
    PROFILE_DIR="debug"
fi

if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
fi

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    # Fallback: read from local.properties
    NDK_FROM_PROPS=$(grep -E "^ndk.dir=" "$ROOT/android/local.properties" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "$NDK_FROM_PROPS" ]; then
        export ANDROID_NDK_HOME="$NDK_FROM_PROPS"
    else
        echo "ANDROID_NDK_HOME not set and ndk.dir not in android/local.properties." >&2
        echo "Run ./scripts/setup.sh first." >&2
        exit 1
    fi
fi

echo "==> Building prism_dsp for Android (profile: $PROFILE_DIR)"
cargo ndk \
    -t arm64-v8a \
    -t armeabi-v7a \
    -t x86_64 \
    -o "$ROOT/android/app/src/main/jniLibs" \
    build $PROFILE_FLAG

echo "==> jniLibs contents:"
ls -lh "$ROOT/android/app/src/main/jniLibs"/*/ 2>/dev/null || true
