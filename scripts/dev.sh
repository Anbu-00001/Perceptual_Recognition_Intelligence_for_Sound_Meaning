#!/usr/bin/env bash
# Single-command dev launcher.
#   ./scripts/dev.sh android        # rebuild rust .so, codegen, flutter run on Android
#   ./scripts/dev.sh ios            # rebuild rust xcframework, codegen, flutter run on iOS (mac only)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-android}"

if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
fi

"$ROOT/scripts/codegen.sh"

case "$TARGET" in
    android)
        "$ROOT/scripts/build_rust_android.sh"
        flutter run -d android
        ;;
    ios)
        "$ROOT/scripts/build_rust_ios.sh"
        cd ios && pod install && cd "$ROOT"
        flutter run -d ios
        ;;
    *)
        echo "Usage: $0 [android|ios]" >&2
        exit 1
        ;;
esac
