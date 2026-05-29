#!/usr/bin/env bash
# Layered test runner.  Each layer is independent; pass --layer to run a subset.
#
#   ./scripts/test.sh                 # cargo + flutter test (host)
#   ./scripts/test.sh --layer rust    # only cargo
#   ./scripts/test.sh --layer dart    # only flutter test
#   ./scripts/test.sh --layer integration   # integration_test on connected device
#   ./scripts/test.sh --layer patrol  # patrol on connected device
#   ./scripts/test.sh --layer maestro # maestro on connected device
#   ./scripts/test.sh --layer all-device    # integration + patrol + maestro
#   ./scripts/test.sh --layer everything    # rust + dart + all-device
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LAYER="host"
if [ "${1:-}" = "--layer" ]; then
    LAYER="${2:-host}"
fi

if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
fi

run_rust() {
    echo "==> rust: cargo test --lib (unit) + --tests (integration)"
    (cd "$ROOT/rust" && cargo test --lib && cargo test --tests)
}

run_dart() {
    echo "==> dart: flutter test"
    flutter test
}

run_integration() {
    echo "==> integration: flutter test integration_test/"
    flutter test integration_test/app_boots_test.dart
    flutter test integration_test/dsp_event_flow_test.dart
    flutter test integration_test/scene_pipeline_test.dart
}

run_patrol() {
    echo "==> patrol: patrol_permissions_test (drives system UI)"
    if ! command -v patrol >/dev/null 2>&1; then
        echo "  patrol_cli not installed: dart pub global activate patrol_cli" >&2
        return 0
    fi
    patrol test --target integration_test/patrol_permissions_test.dart
}

run_maestro() {
    echo "==> maestro: smoke flow"
    if ! command -v maestro >/dev/null 2>&1; then
        echo "  maestro CLI not installed: https://maestro.mobile.dev/getting-started/installing-maestro" >&2
        return 0
    fi
    maestro test .maestro/smoke.yaml
}

case "$LAYER" in
    host) run_rust && run_dart ;;
    rust) run_rust ;;
    dart) run_dart ;;
    integration) run_integration ;;
    patrol) run_patrol ;;
    maestro) run_maestro ;;
    all-device) run_integration && run_patrol && run_maestro ;;
    everything) run_rust && run_dart && run_integration && run_patrol && run_maestro ;;
    *) echo "unknown layer: $LAYER" >&2 && exit 2 ;;
esac

echo "==> done"
