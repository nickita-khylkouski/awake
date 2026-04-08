#!/bin/bash

set -euo pipefail

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/awake-timer-test.XXXXXX)"
STUB_BIN="$TEST_ROOT/bin"
STATE_ROOT="$TEST_ROOT/state"
PMSET_STATE_DIR="$TEST_ROOT/pmset"
PMSET_LOG="$TEST_ROOT/pmset.log"
TEST_HOME="$TEST_ROOT/home"
AGENTS_STATE_FILE="$TEST_ROOT/agents-active"
mkdir -p "$STUB_BIN" "$STATE_ROOT" "$PMSET_STATE_DIR" "$TEST_HOME/.config/awake"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

cat > "$STUB_BIN/sudo" <<'EOF'
#!/bin/bash
set -euo pipefail
log_file="${AWAKE_TEST_PMSET_LOG:?}"
if [ "${1:-}" = "-n" ]; then
    shift
fi
printf '%s\n' "$*" >> "$log_file"
exec "$@"
EOF

cat > "$STUB_BIN/pkill" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/pgrep" <<'EOF'
#!/bin/bash
set -euo pipefail
state_file="${AWAKE_TEST_AGENTS_FILE:?}"
if [ "$(cat "$state_file" 2>/dev/null || echo 0)" = "1" ]; then
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

default_keys=(sleep displaysleep disksleep womp powernap lessbright lidwake acwake ttyskeepawake proximitywake standby autopoweroff hibernatemode)

read_key() {
    local source="$1"
    local key="$2"
    local file="$state_dir/$source.$key"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo 0
    fi
}

write_key() {
    local source="$1"
    local key="$2"
    local value="$3"
    echo "$value" > "$state_dir/$source.$key"
}

print_custom() {
    echo "Battery Power:"
    for key in "${default_keys[@]}"; do
        printf " %-18s %s\n" "$key" "$(read_key battery "$key")"
    done
    echo "AC Power:"
    for key in "${default_keys[@]}"; do
        printf " %-18s %s\n" "$key" "$(read_key ac "$key")"
    done
}

if [ "${1:-}" = "-g" ] && [ "${2:-}" = "batt" ]; then
    echo "Now drawing from 'AC Power'"
    exit 0
fi

if [ "${1:-}" = "-g" ] && [ "${2:-}" = "custom" ]; then
    print_custom
    exit 0
fi

if [ "${1:-}" = "-g" ]; then
    echo "System-wide power settings:"
    echo "Currently in use:"
    echo " disablesleep $(cat "$state_dir/disablesleep")"
    exit 0
fi

scope="${1:-}"
shift || true
case "$scope" in
    -a|-b|-c) ;;
    *)
        exit 0
        ;;
esac

while [ "$#" -gt 0 ]; do
    key="$1"
    value="${2:-}"
    shift 2 || true
    if [ "$key" = "disablesleep" ]; then
        echo "$value" > "$state_dir/disablesleep"
        continue
    fi
    if [ "$scope" = "-a" ]; then
        write_key battery "$key" "$value"
        write_key ac "$key" "$value"
    elif [ "$scope" = "-b" ]; then
        write_key battery "$key" "$value"
    else
        write_key ac "$key" "$value"
    fi
done
EOF

cat > "$STUB_BIN/powermetrics" <<'EOF'
#!/bin/bash
set -euo pipefail
temp="${AWAKE_TEST_CPU_TEMP:-57.5}"
cat <<OUT
**** SMC sensors ****
CPU die temperature: ${temp} C
GPU die temperature: 44.0 C
OUT
EOF

chmod +x "$STUB_BIN"/*

export HOME="$TEST_HOME"
export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export AWAKE_TEST_PMSET_LOG="$PMSET_LOG"
export AWAKE_TEST_PMSET_STATE_DIR="$PMSET_STATE_DIR"
export AWAKE_TEST_AGENTS_FILE="$AGENTS_STATE_FILE"

AWAKE_LIB="$TEST_ROOT/awake-lib.sh"
sed '/^# --- Main ---/,$d' "$REPO_DIR/awake" > "$AWAKE_LIB"
# shellcheck source=/dev/null
source "$AWAKE_LIB"

parse_duration() {
    echo 1
}

log() {
    :
}

notify() {
    :
}

set_agents_active() {
    echo "${1:-0}" > "$AGENTS_STATE_FILE"
}

seed_pmset_state() {
    cat > "$PMSET_STATE_DIR/disablesleep" <<'EOF'
0
EOF
    for source in battery ac; do
        echo 10 > "$PMSET_STATE_DIR/$source.sleep"
        echo 5 > "$PMSET_STATE_DIR/$source.displaysleep"
        echo 10 > "$PMSET_STATE_DIR/$source.disksleep"
        echo 1 > "$PMSET_STATE_DIR/$source.womp"
        echo 1 > "$PMSET_STATE_DIR/$source.powernap"
        echo 1 > "$PMSET_STATE_DIR/$source.lessbright"
        echo 1 > "$PMSET_STATE_DIR/$source.lidwake"
        echo 0 > "$PMSET_STATE_DIR/$source.acwake"
        echo 0 > "$PMSET_STATE_DIR/$source.ttyskeepawake"
        echo 0 > "$PMSET_STATE_DIR/$source.proximitywake"
        echo 1 > "$PMSET_STATE_DIR/$source.standby"
        echo 1 > "$PMSET_STATE_DIR/$source.autopoweroff"
        echo 3 > "$PMSET_STATE_DIR/$source.hibernatemode"
    done
}

setup_state() {
    local name="$1"
    local dir="$STATE_ROOT/$name"
    mkdir -p "$dir"
    PID_FILE="$dir/awake.pid"
    STATE_FILE="$dir/awake-state"
    LAST_ACTIVE_FILE="$dir/awake-last-active"
    CAFFEINE_PID_FILE="$dir/awake-caffeinate.pid"
    FOR_PID_FILE="$dir/awake-for.pid"
    FOR_END_FILE="$dir/awake-for-end"
    FOR_TOKEN_FILE="$dir/awake-for-token"
    BASELINE_FILE="$dir/power-baseline.json"
    DAEMON_LOCK_DIR="$dir/daemon-lock"
    DAEMON_OWNER_FILE="$DAEMON_LOCK_DIR/pid"
    : > "$PMSET_LOG"
    set_agents_active 0
    rm -f /tmp/awake-claude-* /tmp/awake-codex-* 2>/dev/null || true
    seed_pmset_state
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    if [ "$expected" != "$actual" ]; then
        echo "expected '$expected', got '$actual'" >&2
        exit 1
    fi
}

assert_contains() {
    local needle="$1"
    local file="$2"
    if ! grep -Fq "$needle" "$file"; then
        echo "expected '$needle' in $file" >&2
        echo "--- $file ---" >&2
        cat "$file" >&2 || true
        exit 1
    fi
}

assert_not_contains() {
    local needle="$1"
    local file="$2"
    if grep -Fq "$needle" "$file"; then
        echo "did not expect '$needle' in $file" >&2
        echo "--- $file ---" >&2
        cat "$file" >&2 || true
        exit 1
    fi
}

pmset_value() {
    local source="$1"
    local key="$2"
    cat "$PMSET_STATE_DIR/$source.$key"
}

wait_for_timer_exit() {
    local pid
    pid="$(cat "$FOR_PID_FILE")"
    for _ in $(seq 1 30); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    echo "timer process $pid did not exit" >&2
    exit 1
}

test_timer_restores_sleep_ok() {
    setup_state restore
    set_agents_active 0
    cmd_for 1 >/dev/null
    wait_for_timer_exit
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "10" "$(pmset_value battery sleep)"
    assert_equals "5" "$(pmset_value battery displaysleep)"
    assert_equals "3" "$(pmset_value battery hibernatemode)"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    [ ! -f "$BASELINE_FILE" ]
    assert_not_contains "pmset sleepnow" "$PMSET_LOG"
}

test_timer_stays_awake_when_agents_active() {
    setup_state active-agents
    set_agents_active 1
    POLL_INTERVAL=1
    cmd_for 1 >/dev/null
    sleep 1.2
    assert_equals "nosleep-full" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(pmset_value battery sleep)"
    assert_equals "0" "$(pmset_value battery displaysleep)"
    [ -f "$FOR_PID_FILE" ]
    [ -f "$FOR_TOKEN_FILE" ]
    [ -f "$BASELINE_FILE" ]
    assert_not_contains "pmset sleepnow" "$PMSET_LOG"
    activate_yessleep
}

test_manual_yessleep_cancels_timer() {
    setup_state manual-cancel
    set_agents_active 0
    cmd_for 1 >/dev/null
    sleep 0.2
    activate_yessleep
    sleep 1.2
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "10" "$(pmset_value battery sleep)"
    [ ! -f "$FOR_PID_FILE" ]
    [ ! -f "$FOR_END_FILE" ]
    [ ! -f "$FOR_TOKEN_FILE" ]
    assert_not_contains "pmset sleepnow" "$PMSET_LOG"
}

test_timer_waits_until_agents_stop_before_restoring() {
    setup_state wait-for-agents
    set_agents_active 1
    POLL_INTERVAL=1
    cmd_for 1 >/dev/null
    sleep 1.2
    [ -f "$FOR_PID_FILE" ]
    [ -f "$FOR_TOKEN_FILE" ]
    assert_equals "nosleep-full" "$(cat "$STATE_FILE")"

    set_agents_active 0
    wait_for_timer_exit
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "10" "$(pmset_value battery sleep)"
    [ ! -f "$FOR_PID_FILE" ]
    [ ! -f "$FOR_END_FILE" ]
    [ ! -f "$FOR_TOKEN_FILE" ]
}

test_restore_without_baseline_falls_back() {
    setup_state restore-without-baseline
    echo "1" > "$PMSET_STATE_DIR/disablesleep"
    echo "nosleep-full" > "$STATE_FILE"
    restore_normal_sleep_settings
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
}

test_settings_apply_inactive() {
    setup_state settings-inactive
    cmd_settings apply battery sleep 15 displaysleep 7 womp 0 >/dev/null
    assert_equals "15" "$(pmset_value battery sleep)"
    assert_equals "7" "$(pmset_value battery displaysleep)"
    assert_equals "0" "$(pmset_value battery womp)"
    [ ! -f "$BASELINE_FILE" ]
}

test_settings_apply_active_updates_baseline() {
    setup_state settings-active
    activate_nosleep >/dev/null
    assert_equals "0" "$(pmset_value battery sleep)"
    cmd_settings apply battery sleep 15 displaysleep 7 >/dev/null
    assert_equals "0" "$(pmset_value battery sleep)"
    assert_contains "\"sleep\": 15" "$BASELINE_FILE"
    activate_yessleep
    assert_equals "15" "$(pmset_value battery sleep)"
    assert_equals "7" "$(pmset_value battery displaysleep)"
    [ ! -f "$BASELINE_FILE" ]
}

test_settings_dump_json() {
    setup_state settings-dump
    local json
    json="$(cmd_settings dump)"
    [[ "$json" == *"\"effective\""* ]]
    [[ "$json" == *"\"baseline\""* ]]
    [[ "$json" == *"\"availableSources\""* ]]
}

test_temp_json() {
    setup_state temp-json
    export AWAKE_TEST_CPU_TEMP=61.7
    local json
    json="$(cmd_temp json)"
    [[ "$json" == *"\"available\": true"* ]]
    [[ "$json" == *"\"value\": 61.7"* ]]
}

test_timer_restores_sleep_ok
test_timer_stays_awake_when_agents_active
test_manual_yessleep_cancels_timer
test_timer_waits_until_agents_stop_before_restoring
test_restore_without_baseline_falls_back
test_settings_apply_inactive
test_settings_apply_active_updates_baseline
test_settings_dump_json
test_temp_json

echo "timer and settings behavior tests passed"
