#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
case "${1:-all}" in
  format) dart format --output=none --set-exit-if-changed lib test ;;
  analyze) flutter analyze --fatal-infos ;;
  test) flutter test ;;
  build) flutter build web --release --no-web-resources-cdn --pwa-strategy=none ;;
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
