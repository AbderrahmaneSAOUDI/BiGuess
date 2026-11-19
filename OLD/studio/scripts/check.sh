#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
case "${1:-all}" in
  format) dart format --output=none --set-exit-if-changed lib test ;;
  analyze) flutter analyze --fatal-infos ;;
  test) flutter test ;;
  build)
    config_args=()
    if [[ -n "${STUDIO_PUBLIC_CONFIG_FILE:-}" ]]; then
      python3 scripts/public_config.py "$STUDIO_PUBLIC_CONFIG_FILE"
      config_args+=("--dart-define-from-file=$STUDIO_PUBLIC_CONFIG_FILE")
    fi
    flutter build web --release --no-web-resources-cdn --pwa-strategy=none "${config_args[@]}"
    ;;
  all)
    flutter pub get
    bash scripts/check.sh format
    bash scripts/check.sh analyze
    bash scripts/check.sh test
    bash scripts/check.sh build
    python3 scripts/check_boundary.py
    ;;
  *) echo 'Usage: bash scripts/check.sh [all|format|analyze|test|build]' >&2; exit 2 ;;
esac
