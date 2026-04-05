#!/bin/bash

set -euo pipefail

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/awake-timer-test.XXXXXX)"
STUB_BIN="$TEST_ROOT/bin"
STATE_ROOT="$TEST_ROOT/state"
PMSET_LOG="$TEST_ROOT/pmset.log"
mkdir -p "$STUB_BIN" "$STATE_ROOT"

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
if [ "${1:-}" = "pmset" ] && [ "${2:-}" = "-g" ]; then
    exit 0
fi
exit 0
EOF

cat > "$STUB_BIN/pkill" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/pgrep" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${AWAKE_TEST_AGENTS_ACTIVE:-0}" = "1" ]; then
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
if [ "${1:-}" = "-g" ] && [ "${2:-}" = "batt" ]; then
    echo "Now drawing from 'AC Power'"
    exit 0
fi
exit 0
EOF

chmod +x "$STUB_BIN"/*

export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export AWAKE_TEST_PMSET_LOG="$PMSET_LOG"

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
    : > "$PMSET_LOG"
    rm -f /tmp/awake-claude-* /tmp/awake-codex-* 2>/dev/null || true
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

assert_file_equals() {
    local expected="$1"
    local file="$2"
    local got
    got="$(cat "$file")"
    if [ "$got" != "$expected" ]; then
        echo "expected $file to equal '$expected', got '$got'" >&2
        exit 1
    fi
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
    export AWAKE_TEST_AGENTS_ACTIVE=0
    cmd_for 1 >/dev/null
    wait_for_timer_exit
    assert_file_equals "normal" "$STATE_FILE"
    assert_contains "pmset -a disablesleep 0 standby 1 hibernatemode 3 sleep 1 displaysleep 2" "$PMSET_LOG"
    assert_not_contains "pmset sleepnow" "$PMSET_LOG"
}

test_timer_stays_awake_when_agents_active() {
    setup_state active-agents
    export AWAKE_TEST_AGENTS_ACTIVE=1
    cmd_for 1 >/dev/null
    wait_for_timer_exit
    assert_file_equals "nosleep-full" "$STATE_FILE"
    assert_not_contains "pmset sleepnow" "$PMSET_LOG"
    assert_not_contains "pmset -a disablesleep 0 standby 1 hibernatemode 3 sleep 1 displaysleep 2" "$PMSET_LOG"
}

test_manual_yessleep_cancels_timer() {
    setup_state manual-cancel
    export AWAKE_TEST_AGENTS_ACTIVE=0
    cmd_for 1 >/dev/null
    sleep 0.2
    activate_yessleep
    sleep 1.2
    assert_file_equals "normal" "$STATE_FILE"
    [ ! -f "$FOR_PID_FILE" ]
    [ ! -f "$FOR_END_FILE" ]
    assert_not_contains "pmset sleepnow" "$PMSET_LOG"
}

test_timer_restores_sleep_ok
test_timer_stays_awake_when_agents_active
test_manual_yessleep_cancels_timer

echo "timer behavior tests passed"
