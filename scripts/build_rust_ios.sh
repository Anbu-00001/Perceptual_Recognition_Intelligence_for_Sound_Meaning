#!/usr/bin/env bash
# Build the Rust staticlib for iOS device + simulator and assemble an .xcframework
# that Xcode can link against from ios/Runner.
#
# Requires macOS + Xcode command line tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/rust"

if [ "$(uname)" != "Darwin" ]; then
    echo "iOS builds require macOS." >&2
    exit 1
fi

if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
fi

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
cargo build --release --target x86_64-apple-ios

# Combine the two simulator slices into a fat archive.
SIM_DIR="target/ios-sim-universal"
mkdir -p "$SIM_DIR"
lipo -create \
    target/aarch64-apple-ios-sim/release/libprism_dsp.a \
    target/x86_64-apple-ios-sim/release/libprism_dsp.a \
    -output "$SIM_DIR/libprism_dsp.a"

XCFRAMEWORK="$ROOT/ios/prism_rust.xcframework"
rm -rf "$XCFRAMEWORK"

xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libprism_dsp.a \
    -library "$SIM_DIR/libprism_dsp.a" \
    -output "$XCFRAMEWORK"

echo "==> xcframework built at $XCFRAMEWORK"
echo "   Drag it into Xcode -> Runner target -> Frameworks, Libraries, and Embedded Content."
