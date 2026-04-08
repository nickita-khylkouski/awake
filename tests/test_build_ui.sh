#!/bin/bash

set -euo pipefail

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_HOME="$(mktemp -d /tmp/awake-build-ui-test.XXXXXX)"

cleanup() {
    rm -rf "$TEST_HOME"
}
trap cleanup EXIT

HOME="$TEST_HOME" "$REPO_DIR/awake-build-ui" >/dev/null

APP_ROOT="$TEST_HOME/.local/bin/Awake.app"
PLIST="$APP_ROOT/Contents/Info.plist"
BINARY="$APP_ROOT/Contents/MacOS/AwakeUI"

[ -x "$BINARY" ]
[ -f "$PLIST" ]
grep -Fq "<string>awake</string>" "$PLIST"

echo "build ui tests passed"
