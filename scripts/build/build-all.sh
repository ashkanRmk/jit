#!/usr/bin/env bash
# One command from a clean checkout: generate the project, build Jit.app, optionally run all tests.
source "$(dirname "$0")/common.sh"
usage() { echo "usage: scripts/build/build-all.sh [debug|release] [--test]"; }
CONFIG=debug
RUN_TESTS=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --test) RUN_TESTS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument '$arg'" ;;
    esac
done
DIR="$(dirname "$0")"
require_xcode
require_xcodegen
"$DIR/gen-xcodeproj.sh"
"$DIR/build-app.sh" "$CONFIG"
if [[ $RUN_TESTS -eq 1 ]]; then
    "$DIR/test-core.sh"
    "$DIR/test-app.sh"
fi
info "Done"
