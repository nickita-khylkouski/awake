#!/bin/bash

set -euo pipefail

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/awake-modes-test.XXXXXX)"
STUB_BIN="$TEST_ROOT/bin"
STATE_ROOT="$TEST_ROOT/state"
PMSET_STATE_DIR="$TEST_ROOT/pmset"
PMSET_LOG="$TEST_ROOT/pmset.log"
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
exit 0
EOF

cat > "$STUB_BIN/pmset" <<'EOF'
#!/bin/bash
set -euo pipefail
state_dir="${AWAKE_TEST_PMSET_STATE_DIR:?}"
if [ "${1:-}" = "-g" ] && [ "${2:-}" = "batt" ]; then
    echo "Now drawing from 'AC Power'"
    exit 0
fi
if [ "${1:-}" = "-g" ] && [ "${2:-}" = "custom" ]; then
    echo "Battery Power:"
    echo " sleep 10"
    echo " displaysleep 5"
    echo " standby 1"
    echo " hibernatemode 3"
    echo "AC Power:"
    echo " sleep 10"
    echo " displaysleep 5"
    echo " standby 1"
    echo " hibernatemode 3"
    exit 0
fi
if [ "${1:-}" = "-g" ]; then
    echo "System-wide power settings:"
    echo "Currently in use:"
    echo " disablesleep $(cat "$state_dir/disablesleep" 2>/dev/null || echo 0)"
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
    fi
done
EOF

chmod +x "$STUB_BIN"/*

export HOME="$TEST_HOME"
export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export AWAKE_TEST_PMSET_LOG="$PMSET_LOG"
export AWAKE_TEST_PMSET_STATE_DIR="$PMSET_STATE_DIR"

AWAKE_LIB="$TEST_ROOT/awake-lib.sh"
sed '/^# --- Main ---/,$d' "$REPO_DIR/awake" > "$AWAKE_LIB"
# shellcheck source=/dev/null
source "$AWAKE_LIB"

parse_duration() { echo 1; }
log() { :; }
notify() { :; }

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
    DAEMON_LOCK_DIR="$dir/daemon-lock"
    DAEMON_OWNER_FILE="$DAEMON_LOCK_DIR/pid"
    mkdir -p "$LEASES_DIR" "$RULES_DIR"
    echo "agent-safe" > "$MODE_FILE"
    echo 0 > "$PMSET_STATE_DIR/disablesleep"
    rm -f "$DISPLAY_SLEEP_FILE"
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

cmd_mode set running >/dev/null
assert_equals "running" "$(current_default_mode)"
cmd_for 1 >/dev/null
assert_equals "nosleep-display" "$(cat "$STATE_FILE")"
activate_yessleep

cmd_mode set presenting >/dev/null
assert_equals "presenting" "$(current_default_mode)"
cmd_for 1 >/dev/null
assert_equals "nosleep-full" "$(cat "$STATE_FILE")"
activate_yessleep

cmd_mode set agent-safe >/dev/null
assert_equals "agent-safe" "$(current_default_mode)"
echo 1 > "$DISPLAY_SLEEP_FILE"
cmd_for 1 >/dev/null
assert_equals "nosleep-display" "$(cat "$STATE_FILE")"
activate_yessleep

rm -f "$DISPLAY_SLEEP_FILE"
cmd_for 1 >/dev/null
assert_equals "nosleep-full" "$(cat "$STATE_FILE")"

echo "mode behavior tests passed"
