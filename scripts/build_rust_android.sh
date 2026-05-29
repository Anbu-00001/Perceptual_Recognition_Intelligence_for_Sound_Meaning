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
    # Fallback 1: read from local.properties (populated by setup.sh).
    NDK_FROM_PROPS=$(grep -E "^ndk.dir=" "$ROOT/android/local.properties" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "$NDK_FROM_PROPS" ]; then
        export ANDROID_NDK_HOME="$NDK_FROM_PROPS"
    fi
fi

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    # Fallback 2: auto-discover the highest-numbered NDK at the standard locations.
    # This makes `build_rust_android.sh` usable straight after Android Studio
    # installs an NDK, without re-running setup.sh.
    for SDK_ROOT in \
        "${ANDROID_HOME:-}" \
        "${ANDROID_SDK_ROOT:-}" \
        "$HOME/Android/Sdk" \
        "$HOME/Library/Android/sdk" \
        "/usr/local/lib/android/sdk" \
        "/opt/android-sdk"; do
        [ -z "$SDK_ROOT" ] && continue
        [ -d "$SDK_ROOT/ndk" ] || continue
        CAND=$(ls -1 "$SDK_ROOT/ndk" 2>/dev/null | sort -V | tail -n1)
        if [ -n "$CAND" ] && [ -d "$SDK_ROOT/ndk/$CAND" ]; then
            export ANDROID_NDK_HOME="$SDK_ROOT/ndk/$CAND"
            echo "==> Auto-detected NDK at $ANDROID_NDK_HOME"
            break
        fi
    done
fi

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "ANDROID_NDK_HOME not set; ndk.dir missing from android/local.properties;" >&2
    echo "and no NDK found at the standard SDK locations." >&2
    echo "Install one via Android Studio (SDK Manager → SDK Tools → NDK)" >&2
    echo "or run ./scripts/setup.sh." >&2
    exit 1
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
