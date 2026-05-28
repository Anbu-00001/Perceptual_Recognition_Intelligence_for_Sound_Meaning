#!/usr/bin/env bash
# Phase 0 one-shot setup. Idempotent — safe to re-run.
#
# Installs:
#   1. rustup + stable toolchain
#   2. Android cross-compile targets (arm64-v8a, armeabi-v7a, x86_64)
#   3. cargo-ndk      (Android NDK cargo subcommand)
#   4. flutter_rust_bridge_codegen (Rust binary that generates Dart bindings)
#
# Records the NDK location in android/local.properties.
# Runs flutter pub get + codegen to produce the lib/src/rust/ Dart bindings.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> PRISM Phase 0 setup"

# -- 1. Rust toolchain --------------------------------------------------------
if ! command -v cargo >/dev/null 2>&1; then
    echo "==> Installing rustup (this can take ~2 min)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
else
    echo "==> Rust already installed: $(rustc --version)"
fi

# Make cargo available in the current shell session even if just installed.
if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
fi

# -- 2. Android targets -------------------------------------------------------
echo "==> Adding Android cross-compile targets"
rustup target add \
    aarch64-linux-android \
    armv7-linux-androideabi \
    x86_64-linux-android

# -- 3. cargo-ndk -------------------------------------------------------------
if ! command -v cargo-ndk >/dev/null 2>&1; then
    echo "==> Installing cargo-ndk"
    cargo install --locked cargo-ndk
else
    echo "==> cargo-ndk already installed: $(cargo ndk --version 2>&1 | head -1)"
fi

# -- 4. flutter_rust_bridge_codegen ------------------------------------------
NEED_FRB=1
if command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    INSTALLED=$(flutter_rust_bridge_codegen --version 2>&1 | head -1 || true)
    case "$INSTALLED" in
        *"2.1"*|*"2.2"*) NEED_FRB=0 ;;
    esac
fi
if [ "$NEED_FRB" = "1" ]; then
    echo "==> Installing flutter_rust_bridge_codegen (this builds from source; ~5-10 min)"
    cargo install --locked flutter_rust_bridge_codegen --version "^2.12"
else
    echo "==> flutter_rust_bridge_codegen already installed: $INSTALLED"
fi

# -- 5. local.properties: NDK location ---------------------------------------
NDK_CANDIDATES=()
[ -n "${ANDROID_NDK_HOME:-}" ] && NDK_CANDIDATES+=("$ANDROID_NDK_HOME")
[ -n "${ANDROID_HOME:-}" ] && NDK_CANDIDATES+=("$ANDROID_HOME/ndk")
NDK_CANDIDATES+=("$HOME/Android/Sdk/ndk")

NDK_DIR=""
for base in "${NDK_CANDIDATES[@]}"; do
    if [ -d "$base" ]; then
        # Pick the highest-version subdir.
        latest=$(ls -1 "$base" 2>/dev/null | sort -V | tail -1)
        if [ -n "$latest" ] && [ -d "$base/$latest" ]; then
            NDK_DIR="$base/$latest"
            break
        fi
        # Or the base itself is the NDK
        if [ -f "$base/source.properties" ]; then
            NDK_DIR="$base"
            break
        fi
    fi
done

if [ -n "$NDK_DIR" ]; then
    echo "==> Using NDK at $NDK_DIR"
    LOCAL_PROPS="android/local.properties"
    touch "$LOCAL_PROPS"
    # Replace or append ndk.dir
    if grep -q "^ndk.dir=" "$LOCAL_PROPS"; then
        sed -i "s|^ndk.dir=.*|ndk.dir=$NDK_DIR|" "$LOCAL_PROPS"
    else
        echo "ndk.dir=$NDK_DIR" >> "$LOCAL_PROPS"
    fi
    export ANDROID_NDK_HOME="$NDK_DIR"
else
    echo "!! No Android NDK found. Install via Android Studio SDK Manager"
    echo "   then re-run this script."
fi

# -- 6. Flutter dependencies + codegen ---------------------------------------
echo "==> flutter pub get"
flutter pub get

echo "==> Generating Dart bindings from Rust API"
"$ROOT/scripts/codegen.sh"

echo "==> Setup complete. Build for Android with: ./scripts/dev.sh android"
