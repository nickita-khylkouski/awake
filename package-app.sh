#!/bin/bash
# package-app.sh — build a standalone Awake.app and zip it for sharing
set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGING_HOME="$(mktemp -d /tmp/awake-package-home.XXXXXX)"
APP_NAME="Awake.app"
APP_PATH="$DIST_DIR/$APP_NAME"
ZIP_PATH="$DIST_DIR/Awake-macOS.zip"

cleanup() {
    rm -rf "$STAGING_HOME"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR"
rm -rf "$APP_PATH" "$ZIP_PATH"

echo "[package-app] staging build in $STAGING_HOME"
(
    cd "$ROOT_DIR"
    HOME="$STAGING_HOME" bash ./install.sh >/dev/null
)

cp -R "$STAGING_HOME/.local/bin/$APP_NAME" "$APP_PATH"
xattr -cr "$APP_PATH" 2>/dev/null || true

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "[package-app] created:"
echo "  $APP_PATH"
echo "  $ZIP_PATH"
