#!/bin/bash

set -euo pipefail

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/awake-rules-test.XXXXXX)"
STUB_BIN="$TEST_ROOT/bin"
STATE_ROOT="$TEST_ROOT/state"
PMSET_STATE_DIR="$TEST_ROOT/pmset"
PMSET_LOG="$TEST_ROOT/pmset.log"
TEST_HOME="$TEST_ROOT/home"
MATCH_FILE="$TEST_ROOT/process-match"
BATTERY_PCT_FILE="$TEST_ROOT/battery-pct"
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
set -euo pipefail
target="${@: -1}"
if [ -f "${AWAKE_TEST_MATCH_FILE:?}" ] && [ "$(cat "${AWAKE_TEST_MATCH_FILE:?}")" = "$target" ]; then
    echo 4242
    exit 0
fi
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
    pct="$(cat "$state_dir/battery-pct" 2>/dev/null || echo 50)"
    if [ -f "$state_dir/on-battery" ]; then
        echo "Now drawing from 'Battery Power' -InternalBattery-0 ${pct}%; discharging; 4:00 remaining"
    else
        echo "Now drawing from 'AC Power' -InternalBattery-0 ${pct}%; charging; 4:00 remaining"
    fi
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
export AWAKE_TEST_MATCH_FILE="$MATCH_FILE"
export AWAKE_TEST_WIFI_SSID=""
export AWAKE_TEST_EXTERNAL_DISPLAY="0"

AWAKE_LIB="$TEST_ROOT/awake-lib.sh"
sed '/^# --- Main ---/,$d' "$REPO_DIR/awake" > "$AWAKE_LIB"
# shellcheck source=/dev/null
source "$AWAKE_LIB"

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
    echo 50 > "$PMSET_STATE_DIR/battery-pct"
    rm -f "$MATCH_FILE" "$PMSET_STATE_DIR/on-battery"
    export AWAKE_TEST_WIFI_SSID=""
    export AWAKE_TEST_EXTERNAL_DISPLAY="0"
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

if cmd_rules add process codex --priority nope >/dev/null 2>&1; then
    echo "expected invalid priority to fail" >&2
    exit 1
fi

rule_id="$(cmd_rules add process codex --mode presenting --reason "Codex process rule")"
echo codex > "$MATCH_FILE"
sync_rule_leases
reconcile_effective_state
[ -d "$LEASES_DIR/rule-$rule_id" ]
assert_equals "nosleep-full" "$(cat "$STATE_FILE")"
assert_equals "Codex process rule" "$(cat "$WHY_FILE")"

rm -f "$MATCH_FILE"
sync_rule_leases
reconcile_effective_state
assert_equals "normal" "$(cat "$STATE_FILE")"

power_rule="$(cmd_rules add power ac --mode running --reason "AC power rule")"
sync_rule_leases
reconcile_effective_state
[ -d "$LEASES_DIR/rule-$power_rule" ]
assert_equals "nosleep-display" "$(cat "$STATE_FILE")"

touch "$PMSET_STATE_DIR/on-battery"
sync_rule_leases
reconcile_effective_state
assert_equals "normal" "$(cat "$STATE_FILE")"

battery_rule="$(cmd_rules add battery-below 30 --mode presenting --reason "Low battery rule")"
echo 20 > "$PMSET_STATE_DIR/battery-pct"
sync_rule_leases
reconcile_effective_state
[ -d "$LEASES_DIR/rule-$battery_rule" ]
assert_equals "nosleep-full" "$(cat "$STATE_FILE")"

wifi_rule="$(cmd_rules add wifi office --mode running --reason "Office wifi rule")"
export AWAKE_TEST_WIFI_SSID="office"
sync_rule_leases
[ -d "$LEASES_DIR/rule-$wifi_rule" ]

display_rule="$(cmd_rules add display external --mode running --reason "External display rule")"
export AWAKE_TEST_EXTERNAL_DISPLAY="1"
sync_rule_leases
[ -d "$LEASES_DIR/rule-$display_rule" ]

echo "rule behavior tests passed"
