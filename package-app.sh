#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
DIST="$ROOT/dist"
STAGING="$(mktemp -d /tmp/awake-package.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$DIST"
AWAKE_REGISTER_APP=0 AWAKE_INSTALL_ROOT="$STAGING" "$ROOT/awake-build-ui" >/dev/null
rm -rf "$DIST/Awake.app" "$DIST/Awake-macOS.zip"
cp -R "$STAGING/Awake.app" "$DIST/Awake.app"
/usr/bin/ditto -c -k --keepParent "$DIST/Awake.app" "$DIST/Awake-macOS.zip"
echo "Created $DIST/Awake-macOS.zip"
