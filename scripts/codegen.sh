#!/usr/bin/env bash
# Regenerate the Dart bindings + Rust glue from rust/src/api/* signatures.
# Run after any change to a public `pub fn` in rust/src/api/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
fi

if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    echo "flutter_rust_bridge_codegen not found. Run ./scripts/setup.sh first." >&2
    exit 1
fi

flutter_rust_bridge_codegen generate \
    --rust-root "$ROOT/rust" \
    --rust-input "crate::api"
