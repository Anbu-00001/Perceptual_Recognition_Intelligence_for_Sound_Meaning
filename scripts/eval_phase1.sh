#!/usr/bin/env bash
# Runs the Phase 1 kill/continue gate on a connected Android device.
# The eval app is the same Flutter binary, launched with `--dart-define=PRISM_EVAL_MANIFEST=...`
# pointing at a JSON manifest of labeled clips (see lib/src/eval/phase1_eval.dart).
#
# Usage:
#   ./scripts/eval_phase1.sh path/to/manifest.json [hf_token]
set -euo pipefail

MANIFEST="${1:-}"
HF_TOKEN="${2:-${HF_TOKEN:-}}"

if [ -z "$MANIFEST" ] || [ ! -f "$MANIFEST" ]; then
    echo "Usage: $0 <manifest.json> [hf_token]" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Push the manifest + any referenced .wav clips to the device.
DEVICE_DIR="/sdcard/Android/data/com.prism.prism/files/eval"
adb shell mkdir -p "$DEVICE_DIR"
adb push "$MANIFEST" "$DEVICE_DIR/manifest.json"
# Caller is responsible for pushing the .wav files referenced by manifest paths
# (paths in manifest should already be device-local).

flutter run \
    --dart-define=PRISM_MODE=eval \
    --dart-define=PRISM_EVAL_MANIFEST="$DEVICE_DIR/manifest.json" \
    --dart-define=PRISM_EVAL_OUT="$DEVICE_DIR/phase1_report.json" \
    --dart-define=HF_TOKEN="$HF_TOKEN" \
    -d android

echo "==> Eval complete. Pull report:"
echo "  adb pull $DEVICE_DIR/phase1_report.json"
