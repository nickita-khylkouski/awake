#!/bin/bash

set -euo pipefail

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/awake-leases-test.XXXXXX)"
STUB_BIN="$TEST_ROOT/bin"
STATE_ROOT="$TEST_ROOT/state"
PMSET_STATE_DIR="$TEST_ROOT/pmset"
PMSET_LOG="$TEST_ROOT/pmset.log"
OSASCRIPT_LOG="$TEST_ROOT/osascript.log"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$STUB_BIN" "$STATE_ROOT" "$PMSET_STATE_DIR" "$TEST_HOME/.config/awake"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

cat > "$STUB_BIN/sudo" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "-n" ]; then
    shift
fi
printf '%s\n' "$*" >> "${AWAKE_TEST_PMSET_LOG:?}"
exec "$@"
EOF

cat > "$STUB_BIN/pkill" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF

cat > "$STUB_BIN/caffeinate" <<'EOF'
#!/bin/bash
sleep 30
EOF

cat > "$STUB_BIN/osascript" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'osascript %s\n' "$*" >> "${AWAKE_TEST_OSASCRIPT_LOG:?}"
if [ -f "${AWAKE_TEST_PMSET_STATE_DIR:?}/fail-osascript-sleep" ]; then
    exit 1
fi
echo 1 > "${AWAKE_TEST_PMSET_STATE_DIR:?}/osascript-slept"
exit 0
EOF

cat > "$STUB_BIN/pmset" <<'EOF'
#!/bin/bash
set -euo pipefail
state_dir="${AWAKE_TEST_PMSET_STATE_DIR:?}"

read_key() {
    local key="$1"
    local file="$state_dir/$key"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo 0
    fi
}

if [ "${1:-}" = "-g" ] && [ "${2:-}" = "batt" ]; then
    pct="$(read_key battery-pct)"
    if [ -f "$state_dir/on-battery" ]; then
        echo "Now drawing from 'Battery Power'"
        echo " -InternalBattery-0 (id=1234567)\t${pct}%; discharging; 2:00 remaining"
    else
        echo "Now drawing from 'AC Power'"
        echo " -InternalBattery-0 (id=1234567)\t${pct}%; charging; 2:00 remaining"
    fi
    exit 0
fi

if [ "${1:-}" = "-g" ] && [ "${2:-}" = "custom" ]; then
    echo "Battery Power:"
    echo " sleep $(read_key battery.sleep)"
    echo " displaysleep $(read_key battery.displaysleep)"
    echo " standby 1"
    echo " hibernatemode 3"
    echo "AC Power:"
    echo " sleep $(read_key ac.sleep)"
    echo " displaysleep $(read_key ac.displaysleep)"
    echo " standby 1"
    echo " hibernatemode 3"
    exit 0
fi

if [ "${1:-}" = "-g" ]; then
    echo "System-wide power settings:"
    echo "Currently in use:"
    echo " disablesleep $(read_key disablesleep)"
    exit 0
fi

if [ "${1:-}" = "displaysleepnow" ]; then
    echo 1 > "$state_dir/display-slept"
    if [ -f "$state_dir/fail-displaysleepnow" ]; then
        exit 1
    fi
    exit 0
fi

if [ "${1:-}" = "sleepnow" ]; then
    if [ -f "$state_dir/fail-sleepnow" ]; then
        exit 1
    fi
    echo 1 > "$state_dir/pmset-slept"
    exit 0
fi

scope="${1:-}"
shift || true
while [ "$#" -gt 0 ]; do
    key="$1"
    value="${2:-}"
    shift 2 || true
    if [ "$key" = "disablesleep" ]; then
        echo "$value" > "$state_dir/disablesleep"
        continue
    fi
    case "$scope" in
        -a)
            echo "$value" > "$state_dir/battery.$key"
            echo "$value" > "$state_dir/ac.$key"
            ;;
        -b)
            echo "$value" > "$state_dir/battery.$key"
            ;;
        -c)
            echo "$value" > "$state_dir/ac.$key"
            ;;
    esac
done
EOF

chmod +x "$STUB_BIN"/*

export HOME="$TEST_HOME"
export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export AWAKE_TEST_PMSET_LOG="$PMSET_LOG"
export AWAKE_TEST_PMSET_STATE_DIR="$PMSET_STATE_DIR"
export AWAKE_TEST_OSASCRIPT_LOG="$OSASCRIPT_LOG"

AWAKE_LIB="$TEST_ROOT/awake-lib.sh"
sed '/^# --- Main ---/,$d' "$REPO_DIR/awake" > "$AWAKE_LIB"
# shellcheck source=/dev/null
source "$AWAKE_LIB"

log() { :; }
notify() { :; }
active_daemon_pid() { return 1; }

setup_state() {
    local dir="$STATE_ROOT/case"
    mkdir -p "$dir"
    PID_FILE="$dir/awake.pid"
    STATE_FILE="$dir/awake-state"
    LAST_ACTIVE_FILE="$dir/awake-last-active"
    CAFFEINE_PID_FILE="$dir/awake-caffeinate.pid"
    FOR_PID_FILE="$dir/awake-for.pid"
    FOR_END_FILE="$dir/awake-for-end"
    FOR_TOKEN_FILE="$dir/awake-for-token"
    DISPLAY_SLEEP_FILE="$dir/awake-display-sleep"
    LEASES_DIR="$dir/leases"
    RULES_DIR="$dir/rules.d"
    BASELINE_FILE="$dir/power-baseline.json"
    MODE_FILE="$dir/default-mode"
    WHY_FILE="$dir/awake-why"
    BATTERY_GUARD_FILE="$dir/awake-battery-guard"
    DAEMON_LOCK_DIR="$dir/daemon-lock"
    DAEMON_OWNER_FILE="$DAEMON_LOCK_DIR/pid"
    mkdir -p "$LEASES_DIR" "$RULES_DIR"
    echo "agent-safe" > "$MODE_FILE"
    : > "$PMSET_LOG"
    : > "$OSASCRIPT_LOG"
    echo 0 > "$PMSET_STATE_DIR/disablesleep"
    echo 50 > "$PMSET_STATE_DIR/battery-pct"
    rm -f "$PMSET_STATE_DIR/on-battery"
    echo 10 > "$PMSET_STATE_DIR/battery.sleep"
    echo 10 > "$PMSET_STATE_DIR/ac.sleep"
    echo 5 > "$PMSET_STATE_DIR/battery.displaysleep"
    echo 5 > "$PMSET_STATE_DIR/ac.displaysleep"
    rm -f "$PMSET_STATE_DIR/pmset-slept" "$PMSET_STATE_DIR/osascript-slept" "$PMSET_STATE_DIR/display-slept"
    rm -f "$PMSET_STATE_DIR/fail-sleepnow" "$PMSET_STATE_DIR/fail-displaysleepnow" "$PMSET_STATE_DIR/fail-osascript-sleep"
    rm -f "$BATTERY_GUARD_FILE"
}

set_on_battery() {
    touch "$PMSET_STATE_DIR/on-battery"
}

set_charging() {
    rm -f "$PMSET_STATE_DIR/on-battery"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    if [ "$expected" != "$actual" ]; then
        echo "expected '$expected', got '$actual'" >&2
        exit 1
    fi
}

setup_state

set_on_battery
echo 4 > "$PMSET_STATE_DIR/battery-pct"
enforce_battery_guard
grep -q "pmset displaysleepnow" "$PMSET_LOG"
grep -q "pmset sleepnow" "$PMSET_LOG"
[ -f "$PMSET_STATE_DIR/pmset-slept" ]

setup_state
set_on_battery
touch "$PMSET_STATE_DIR/fail-sleepnow"
echo 4 > "$PMSET_STATE_DIR/battery-pct"
enforce_battery_guard
grep -q "pmset displaysleepnow" "$PMSET_LOG"
grep -q "pmset sleepnow" "$PMSET_LOG"
grep -q 'System Events" to sleep' "$OSASCRIPT_LOG"
[ -f "$PMSET_STATE_DIR/osascript-slept" ]

setup_state
set_charging
echo 4 > "$PMSET_STATE_DIR/battery-pct"
if enforce_battery_guard; then
    echo "battery guard should not trigger while charging" >&2
    exit 1
fi
[ ! -s "$PMSET_LOG" ]

setup_state

lease_create_or_update "run-command" "command" "running" "Command lease" 85 "" "test"
lease_create_or_update "manual-toggle" "manual" "presenting" "Manual lease" 100 "" "test"
reconcile_effective_state
assert_equals "nosleep-full" "$(cat "$STATE_FILE")"
assert_equals "Manual lease" "$(cat "$WHY_FILE")"

lease_remove "manual-toggle"
reconcile_effective_state
assert_equals "nosleep-display" "$(cat "$STATE_FILE")"
assert_equals "Command lease" "$(cat "$WHY_FILE")"

lease_remove "run-command"
reconcile_effective_state
assert_equals "normal" "$(cat "$STATE_FILE")"
[ ! -f "$WHY_FILE" ]

lease_create_or_update "first" "manual" "running" "First lease" 50 "" "test"
lease_create_or_update "second" "manual" "presenting" "Second lease" 50 "" "test"
echo 100 > "$LEASES_DIR/first/started_at"
echo 200 > "$LEASES_DIR/second/started_at"
assert_equals "second" "$(best_lease_id)"

lease_create_or_update "expired" "manual" "presenting" "Expired lease" 40 "" "test"
echo 1 > "$LEASES_DIR/expired/expires_at"
cleanup_expired_leases
[ ! -d "$LEASES_DIR/expired" ]

rm -rf "$LEASES_DIR"
mkdir -p "$LEASES_DIR"
lease_create_or_update "daemon-agent" "daemon" "agent-safe" "Detected active coding agents" 70 "" "daemon"
reconcile_effective_state
[ ! -d "$LEASES_DIR/daemon-agent" ]
assert_equals "normal" "$(cat "$STATE_FILE")"

setup_state
set_on_battery
echo 4 > "$PMSET_STATE_DIR/battery-pct"
lease_create_or_update "manual-toggle" "manual" "presenting" "Manual lease" 100 "" "test"
reconcile_effective_state
[ ! -d "$LEASES_DIR/manual-toggle" ]
assert_equals "normal" "$(cat "$STATE_FILE")"
grep -q "pmset displaysleepnow" "$PMSET_LOG"
grep -q "pmset sleepnow" "$PMSET_LOG"

setup_state
set_on_battery
touch "$PMSET_STATE_DIR/fail-sleepnow"
echo 4 > "$PMSET_STATE_DIR/battery-pct"
lease_create_or_update "manual-toggle" "manual" "presenting" "Manual lease" 100 "" "test"
reconcile_effective_state
[ ! -d "$LEASES_DIR/manual-toggle" ]
assert_equals "normal" "$(cat "$STATE_FILE")"
grep -q 'System Events" to sleep' "$OSASCRIPT_LOG"

setup_state
set_charging
echo 4 > "$PMSET_STATE_DIR/battery-pct"
lease_create_or_update "manual-toggle" "manual" "presenting" "Manual lease" 100 "" "test"
reconcile_effective_state
[ -d "$LEASES_DIR/manual-toggle" ]
assert_equals "nosleep-full" "$(cat "$STATE_FILE")"

echo "lease behavior tests passed"
