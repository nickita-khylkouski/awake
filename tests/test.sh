#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/awake-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

bash -n "$ROOT/awake" "$ROOT/awake-build-ui" "$ROOT/install.sh" "$ROOT/package-app.sh"
pass "shell syntax"

xcrun swiftc -target arm64-apple-macos13.0 \
    -framework AppKit -framework Carbon -framework IOKit -framework ServiceManagement \
    -typecheck "$ROOT/ui/main.swift"
pass "Swift typecheck at macOS 13 deployment target"

cat > "$TMP/open" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$AWAKE_TEST_LOG"
SH
chmod +x "$TMP/open"
export AWAKE_OPEN_BIN="$TMP/open" AWAKE_TEST_LOG="$TMP/urls" AWAKE_STATE_FILE="$TMP/state.json" AWAKE_COMMAND_FILE="$TMP/command"

"$ROOT/awake" for 30m
grep -Fq 'start seconds 1800' "$TMP/command" || fail "30m command"
pass "duration parsing"

if "$ROOT/awake" for 0m >/dev/null 2>&1; then fail "zero duration accepted"; fi
if "$ROOT/awake" for banana >/dev/null 2>&1; then fail "invalid duration accepted"; fi
pass "invalid durations rejected"

"$ROOT/awake" nosleep-display
grep -Fq 'start display 0' "$TMP/command" || fail "display mode command"
"$ROOT/awake" off
grep -Fq 'stop' "$TMP/command" || fail "stop command"
pass "legacy aliases"

"$ROOT/awake" status --json | /usr/bin/python3 -m json.tool >/dev/null
pass "status JSON"

if rg -n 'sleepnow|pgrep|daemon-agent|awake-leases|CoreBrightness|DisplayServices' \
    "$ROOT/ui/main.swift" "$ROOT/awake"; then
    fail "removed daemon or private power machinery is still referenced"
fi
pass "daemon-free implementation"

rg -q 'kIOPMAssertionTypePreventUserIdleSystemSleep' "$ROOT/ui/main.swift" || fail "system assertion missing"
rg -q 'kIOPMAssertionTypePreventUserIdleDisplaySleep' "$ROOT/ui/main.swift" || fail "display assertion missing"
rg -q 'event.keyCode == 53' "$ROOT/ui/main.swift" || fail "Escape recovery missing"
pass "power and blackout safety paths"

tarball="$(cd "$ROOT" && npm pack --silent --pack-destination "$TMP" | tail -1)"
npm install --silent --prefix "$TMP/npm" "$TMP/$tarball"
version="$($TMP/npm/node_modules/.bin/awake --version)"
[ "$version" = "awake-agent 3.0.0" ] || fail "npm bin symlink resolution"
[ -x "$TMP/npm/node_modules/awake-agent/awake-build-ui" ] || fail "npm build helper missing"
pass "npm package entrypoint"

echo "All tests passed."
