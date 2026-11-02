#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/awake-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

bash -n "$ROOT/awake" "$ROOT/awake-power" "$ROOT/awake-build-ui" "$ROOT/install.sh" "$ROOT/package-app.sh"
pass "shell syntax"

xcrun swiftc -target arm64-apple-macos13.0 \
    -framework AppKit -framework Carbon -framework IOKit -framework ServiceManagement -framework SwiftUI \
    -typecheck "$ROOT/ui/main.swift" "$ROOT/ui/PowerPolicy.swift"
pass "Swift typecheck at macOS 13 deployment target"

cat > "$TMP/open" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$AWAKE_TEST_LOG"
SH
chmod +x "$TMP/open"
export AWAKE_OPEN_BIN="$TMP/open" AWAKE_TEST_LOG="$TMP/urls" AWAKE_STATE_FILE="$TMP/state.json" AWAKE_COMMAND_FILE="$TMP/command"

"$ROOT/awake" for 30m
grep -Fq 'awake://start?seconds=1800' "$TMP/urls" || fail "30m command"
pass "duration parsing"

if "$ROOT/awake" for 0m >/dev/null 2>&1; then fail "zero duration accepted"; fi
if "$ROOT/awake" for banana >/dev/null 2>&1; then fail "invalid duration accepted"; fi
if "$ROOT/awake" for 99999999999999999999999h >/dev/null 2>&1; then fail "overflow accepted"; fi
pass "invalid durations rejected"

"$ROOT/awake" nosleep-display
grep -Fq 'awake://start?display=0' "$TMP/urls" || fail "display mode command"
"$ROOT/awake" off
grep -Fq 'awake://stop' "$TMP/urls" || fail "stop command"
pass "legacy aliases"

"$ROOT/awake" status --json | /usr/bin/python3 -m json.tool >/dev/null
pass "status JSON"
export AWAKE_CLOSED_LID_MARKER="$TMP/closed-lid"
printf 'owned' > "$AWAKE_CLOSED_LID_MARKER"
printf '{"pid":2147483647,"active":true,"closedLidActive":true,"timerEndsAt":9999999999}' > "$AWAKE_STATE_FILE"
"$ROOT/awake" status --json | /usr/bin/python3 -c 'import json,sys; s=json.load(sys.stdin); assert not s["active"] and not s["appRunning"] and s["restoreFailed"] and "timerEndsAt" not in s'
rm "$AWAKE_STATE_FILE" "$AWAKE_CLOSED_LID_MARKER"
pass "stopped app does not claim active assertions or hide pending power restoration"

if rg -n 'sleepnow|pgrep|daemon-agent|awake-leases|CoreBrightness|DisplayServices' \
    "$ROOT/ui/main.swift" "$ROOT/awake"; then
    fail "removed daemon or private power machinery is still referenced"
fi
pass "daemon-free implementation"

rg -q 'kIOPMAssertionTypePreventUserIdleSystemSleep' "$ROOT/ui/main.swift" || fail "system assertion missing"
rg -q 'kIOPMAssertionTypePreventUserIdleDisplaySleep' "$ROOT/ui/main.swift" || fail "display assertion missing"
rg -Fq 'override func mouseDown(with event: NSEvent) {}' "$ROOT/ui/main.swift" || fail "blackout must ignore clicks"
rg -q 'pmset -a disablesleep 1' "$ROOT/awake-power" || fail "closed-lid enable path missing"
rg -q 'pmset -a disablesleep.*prior' "$ROOT/awake-power" || fail "closed-lid restore path missing"
rg -q 'helperPath, "on", owner' "$ROOT/ui/main.swift" || fail "coordinated power helper missing"
rg -Fq 'statusItem(withLength: NSStatusItem.squareLength)' "$ROOT/ui/main.swift" || fail "compact menu bar item missing"
rg -Fq 'NSApp.setActivationPolicy(.regular)' "$ROOT/ui/main.swift" || fail "Dock app activation policy missing"
rg -Fq '<key>LSUIElement</key><false/>' "$ROOT/awake-build-ui" || fail "Dock app bundle setting missing"
rg -Fq 'statusItem.autosaveName = "com.awake"' "$ROOT/ui/main.swift" || fail "stable menu bar identity missing"
rg -Fq 'statusItem.isVisible = true' "$ROOT/ui/main.swift" || fail "menu bar visibility recovery missing"
if rg -q 'UserDefaults.standard.set\(150, forKey: positionKey\)' "$ROOT/ui/main.swift"; then fail "private menu bar positioning still present"; fi
rg -Fq 'private var cachedSetupComplete: Bool?' "$ROOT/ui/main.swift" || fail "closed-lid setup verification is not cached"
pass "power and blackout safety paths"

cat > "$TMP/pmset" <<'SH'
#!/bin/sh
if [ "$1" = -g ]; then
    printf ' SleepDisabled\t\t%s\n' "$(cat "$AWAKE_POWER_TEST_VALUE")"
elif [ "$1" = -a ] && [ "$2" = disablesleep ]; then
    printf '%s\n' "$3" > "$AWAKE_POWER_TEST_VALUE"
else
    exit 2
fi
SH
chmod +x "$TMP/pmset"
sed -e "s#/Library/Application Support/Awake/power-state#$TMP/power-state#g" \
    -e "s#/var/run/awake-disablesleep.lock#$TMP/power-state.lock#g" \
    -e 's#^/usr/sbin/chown -R root:wheel.*$#:#' \
    -e "s#/usr/bin/pmset#$TMP/pmset#g" "$ROOT/awake-power" > "$TMP/awake-power"
chmod +x "$TMP/awake-power"
export AWAKE_POWER_TEST_VALUE="$TMP/power-value"
printf '0\n' > "$AWAKE_POWER_TEST_VALUE"
"$TMP/awake-power" on 501
"$TMP/awake-power" on 502
"$TMP/awake-power" off 501
[ "$(cat "$AWAKE_POWER_TEST_VALUE")" = 1 ] || fail "one user restored while another was active"
"$TMP/awake-power" off 502
[ "$(cat "$AWAKE_POWER_TEST_VALUE")" = 0 ] || fail "prior zero value was not restored"
printf '1\n' > "$AWAKE_POWER_TEST_VALUE"
"$TMP/awake-power" on 501
"$TMP/awake-power" off 501
[ "$(cat "$AWAKE_POWER_TEST_VALUE")" = 1 ] || fail "prior one value was not preserved"
pass "multi-user power ownership and prior-state restoration"

tarball="$(cd "$ROOT" && npm pack --silent --pack-destination "$TMP" | tail -1)"
npm install --silent --prefix "$TMP/npm" "$TMP/$tarball"
version="$($TMP/npm/node_modules/.bin/awake --version)"
[ "$version" = "awake-agent 3.2.0" ] || fail "npm bin symlink resolution"
[ -x "$TMP/npm/node_modules/awake-agent/awake-build-ui" ] || fail "npm build helper missing"
pass "npm package entrypoint"

cp "$ROOT/tests/power-policy.swift" "$TMP/main.swift"
xcrun swiftc "$ROOT/ui/PowerPolicy.swift" "$TMP/main.swift" -o "$TMP/power-tests"
"$TMP/power-tests"

echo "All tests passed."
