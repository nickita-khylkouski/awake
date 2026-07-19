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

cleanup_test() {
    rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

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
exec -a caffeinate sleep 30
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
    if [ -f "$state_dir/use-sleepdisabled-format" ]; then
        printf " SleepDisabled\t\t%s\n" "$(cat "$state_dir/disablesleep")"
    else
        echo "Currently in use:"
        echo " disablesleep $(cat "$state_dir/disablesleep")"
    fi
    exit 0
fi

if [ "${AWAKE_TEST_PMSET_FAIL_WRITE:-0}" = "1" ]; then
    exit 42
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

ensure_runtime_ready() { return 0; }
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
    DISPLAY_SLEEP_FILE="$dir/awake-display-sleep"
    RUNTIME_READY_FILE="$dir/awake-runtime-ready"
    RUNTIME_HEARTBEAT_FILE="$dir/awake-runtime-heartbeat"
    LEASES_DIR="$dir/leases"
    RULES_DIR="$dir/rules.d"
    BASELINE_FILE="$dir/power-baseline.json"
    OVERRIDE_MARKER_FILE="$dir/power-override-active"
    MODE_FILE="$dir/default-mode"
    DAEMON_LOCK_DIR="$dir/daemon-lock"
    DAEMON_OWNER_FILE="$DAEMON_LOCK_DIR/pid"
    RECONCILE_LOCK_FILE="$dir/reconcile-lock"
    WHY_FILE="$dir/awake-why"
    HOOK_STATE_DIR="$dir/hooks"
    : > "$PMSET_LOG"
    set_agents_active 0
    seed_pmset_state
    rm -f "$PMSET_STATE_DIR/use-sleepdisabled-format"
    mkdir -p "$LEASES_DIR" "$RULES_DIR" "$HOOK_STATE_DIR"
    echo "agent-safe" > "$MODE_FILE"
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

test_timer_replaces_existing_manual_session() {
    setup_state timer-replaces-manual
    set_agents_active 0
    activate_nosleep >/dev/null
    [ -d "$LEASES_DIR/manual-toggle" ]
    cmd_for 1 >/dev/null
    [ ! -d "$LEASES_DIR/manual-toggle" ]
    [ -d "$LEASES_DIR/manual-timer" ]
    wait_for_timer_exit
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
}

test_timer_preserves_running_command_lease() {
    setup_state timer-with-command
    set_agents_active 0
    cmd_run_command sleep 2 >/dev/null &
    local run_pid=$!
    local attempt=0
    while [ ! -d "$LEASES_DIR/run-command" ] && [ "$attempt" -lt 100 ]; do
        sleep 0.01
        attempt=$(( attempt + 1 ))
    done
    [ -d "$LEASES_DIR/run-command" ]
    cmd_for 1 >/dev/null
    sleep 1.2
    [ -d "$LEASES_DIR/run-command" ]
    [ ! -d "$LEASES_DIR/manual-timer" ]
    [[ "$(cat "$STATE_FILE")" == nosleep* ]]
    wait "$run_pid"
    assert_equals "normal" "$(cat "$STATE_FILE")"
}

test_background_reconcile_lock_uses_real_process_pid() {
    setup_state reconcile-owner
    local owner_file="$RECONCILE_LOCK_FILE"
    (
        acquire_reconcile_lock
        sleep 0.2
        release_reconcile_lock
    ) &
    local holder_pid=$!
    local attempt=0
    while [ ! -f "$owner_file" ] && [ "$attempt" -lt 50 ]; do
        sleep 0.01
        attempt=$(( attempt + 1 ))
    done
    [ -f "$owner_file" ]
    local owner
    owner="$(cat "$owner_file")"
    local owner_pid="${owner%%:*}"
    [ "$owner_pid" != "$$" ]
    kill -0 "$owner_pid" 2>/dev/null
    wait "$holder_pid"
    [ ! -e "$RECONCILE_LOCK_FILE" ]
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

test_cancel_timer_command_clears_lease() {
    setup_state cancel-command
    set_agents_active 0
    cmd_for 1 >/dev/null
    sleep 0.2
    cmd_cancel_timer >/dev/null
    sleep 1.1
    assert_equals "normal" "$(cat "$STATE_FILE")"
    [ ! -d "$LEASES_DIR/manual-timer" ]
    [ ! -f "$FOR_PID_FILE" ]
}

test_replacing_timer_publishes_new_owner_atomically() {
    setup_state replace-timer
    cmd_for 1 >/dev/null
    local old_pid
    old_pid="$(cat "$FOR_PID_FILE")"

    cmd_for 1 >/dev/null
    local new_pid owner_pid
    new_pid="$(cat "$FOR_PID_FILE")"
    owner_pid="$(cat "$LEASES_DIR/manual-timer/owner_pid")"

    [ "$new_pid" != "$old_pid" ]
    assert_equals "$new_pid" "$owner_pid"
    [ -f "$LEASES_DIR/manual-timer/ready" ]
    [ -d "$LEASES_DIR/manual-timer" ]
    cmd_cancel_timer >/dev/null
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

test_launch_recovery_restores_after_crashed_daemon() {
    setup_state crash-recovery
    activate_nosleep >/dev/null
    assert_equals "nosleep-full" "$(cat "$STATE_FILE")"
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    [ -f "$BASELINE_FILE" ]
    [ -f "$OVERRIDE_MARKER_FILE" ]

    lease_remove "manual-toggle"
    lease_create_or_update "daemon-agent" "daemon" "presenting" "Detected active coding agents" 70 "" "daemon"
    set_agents_active 0
    recover_power_state_on_launch

    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    [ ! -f "$BASELINE_FILE" ]
    [ ! -f "$OVERRIDE_MARKER_FILE" ]
    [ ! -d "$LEASES_DIR/daemon-agent" ]
}

test_reconcile_repairs_kernel_state_mismatch() {
    setup_state kernel-mismatch
    activate_nosleep >/dev/null
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"

    echo "0" > "$PMSET_STATE_DIR/disablesleep"
    reconcile_effective_state

    assert_equals "nosleep-full" "$(cat "$STATE_FILE")"
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    activate_yessleep
}

test_launch_recovery_leaves_unowned_kernel_setting_alone() {
    setup_state unowned-kernel-setting
    echo "1" > "$PMSET_STATE_DIR/disablesleep"

    recover_power_state_on_launch

    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    [ ! -f "$BASELINE_FILE" ]
    [ ! -f "$OVERRIDE_MARKER_FILE" ]
}

test_fix_clears_unowned_disablesleep() {
    setup_state fix-clears-unowned
    echo "1" > "$PMSET_STATE_DIR/disablesleep"
    touch "$PMSET_STATE_DIR/use-sleepdisabled-format"

    cmd_fix > "$STATE_ROOT/cmd-out.txt" 2>&1

    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    assert_contains "Cleared disablesleep that Awake did not set" "$STATE_ROOT/cmd-out.txt"
    [ ! -f "$RECONCILE_LOCK_FILE" ]
}

test_disablesleep_parsers_accept_real_mac_format() {
    setup_state real-mac-format
    echo "1" > "$PMSET_STATE_DIR/disablesleep"
    touch "$PMSET_STATE_DIR/use-sleepdisabled-format"

    assert_equals "1" "$(current_disablesleep_value)"
    ensure_baseline_snapshot

    assert_contains '"disablesleep": 1' "$BASELINE_FILE"
}

test_fix_noop_when_no_unowned_override() {
    setup_state fix-noop-clean
    echo "0" > "$PMSET_STATE_DIR/disablesleep"

    cmd_fix > "$STATE_ROOT/cmd-out.txt" 2>&1

    assert_contains "Nothing to fix" "$STATE_ROOT/cmd-out.txt"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    [ ! -f "$RECONCILE_LOCK_FILE" ]
}

test_fix_releases_lock_when_pmset_fails() {
    setup_state fix-pmset-failure
    echo "1" > "$PMSET_STATE_DIR/disablesleep"
    touch "$PMSET_STATE_DIR/use-sleepdisabled-format"
    export AWAKE_TEST_PMSET_FAIL_WRITE=1

    local rc=0
    cmd_fix > "$STATE_ROOT/cmd-out.txt" 2>&1 || rc=$?

    unset AWAKE_TEST_PMSET_FAIL_WRITE
    assert_equals "1" "$rc"
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    assert_contains "Could not clear disablesleep" "$STATE_ROOT/cmd-out.txt"
    [ ! -f "$RECONCILE_LOCK_FILE" ]
}

test_fix_refuses_to_clear_owned_session() {
    setup_state fix-owned-session
    activate_nosleep >/dev/null
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"

    cmd_fix > "$STATE_ROOT/cmd-out.txt" 2>&1

    assert_contains "Nothing to fix" "$STATE_ROOT/cmd-out.txt"
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    assert_not_contains "disablesleep 0" "$PMSET_LOG"
}

test_fix_does_not_clear_while_reconcile_lock_held() {
    setup_state fix-lock-contention
    echo "1" > "$PMSET_STATE_DIR/disablesleep"

    sleep 10 &
    local holder=$!
    printf '%s\n' "$holder:0:contend" > "$RECONCILE_LOCK_FILE"

    local rc=0
    cmd_fix > "$STATE_ROOT/cmd-out.txt" 2>&1 || rc=$?

    kill "$holder" 2>/dev/null || true

    assert_equals "1" "$rc"
    assert_contains "Could not acquire" "$STATE_ROOT/cmd-out.txt"
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    assert_equals "" "$(cat "$PMSET_LOG")"
    assert_equals "$holder:0:contend" "$(cat "$RECONCILE_LOCK_FILE")"
    rm -f "$RECONCILE_LOCK_FILE"
}

test_unowned_disablesleep_surfaces_in_why() {
    setup_state unowned-why
    echo "1" > "$PMSET_STATE_DIR/disablesleep"

    why_summary > "$STATE_ROOT/cmd-out.txt" 2>&1

    assert_contains "Awake did not set it" "$STATE_ROOT/cmd-out.txt"
    assert_contains "awake fix" "$STATE_ROOT/cmd-out.txt"
}

test_unowned_disablesleep_surfaces_in_warnings() {
    setup_state unowned-warnings
    echo "1" > "$PMSET_STATE_DIR/disablesleep"

    warnings_json > "$STATE_ROOT/cmd-out.txt" 2>&1

    assert_contains "Awake did not set it" "$STATE_ROOT/cmd-out.txt"
    assert_contains "run 'awake fix' to clear it" "$STATE_ROOT/cmd-out.txt"
}

test_fix_rechecks_ownership_after_acquiring_lock() {
    setup_state fix-recheck-race
    echo "1" > "$PMSET_STATE_DIR/disablesleep"

    # Simulate a session that becomes owned between the first guard and the
    # post-lock recheck: report unowned on the first call, owned on the second.
    # This exercises the recheck-under-lock branch that closes the race, which
    # a test that is owned up front never reaches (it bails at the first guard).
    local saved_fn
    saved_fn="$(declare -f unowned_disablesleep_active)"
    __recheck_calls=0
    unowned_disablesleep_active() {
        __recheck_calls=$(( __recheck_calls + 1 ))
        [ "$__recheck_calls" -eq 1 ]
    }

    local rc=0
    cmd_fix > "$STATE_ROOT/cmd-out.txt" 2>&1 || rc=$?

    eval "$saved_fn"

    assert_equals "0" "$rc"
    assert_contains "an Awake session is now holding the override" "$STATE_ROOT/cmd-out.txt"
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    assert_equals "" "$(cat "$PMSET_LOG")"
    [ ! -f "$RECONCILE_LOCK_FILE" ]
}

test_failed_recovery_keeps_ownership_for_retry() {
    setup_state recovery-retry
    activate_nosleep >/dev/null
    lease_remove "manual-toggle"
    export AWAKE_TEST_PMSET_FAIL_WRITE=1

    if recover_power_state_on_launch; then
        echo "expected recovery to fail while pmset writes are blocked" >&2
        exit 1
    fi

    [ -f "$BASELINE_FILE" ]
    [ -f "$OVERRIDE_MARKER_FILE" ]
    assert_equals "nosleep-full" "$(cat "$STATE_FILE")"

    unset AWAKE_TEST_PMSET_FAIL_WRITE
    recover_power_state_on_launch
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    [ ! -f "$BASELINE_FILE" ]
    [ ! -f "$OVERRIDE_MARKER_FILE" ]
}

test_runtime_signal_preserves_state_for_supervisor_restart() {
    setup_state cleanup-restart
    activate_nosleep >/dev/null
    lease_remove "manual-toggle"
    lease_create_or_update "daemon-agent" "daemon" "presenting" "Detected active coding agents" 70 "" "daemon"
    mkdir -p "$DAEMON_LOCK_DIR"
    echo $$ > "$DAEMON_OWNER_FILE"
    echo $$ > "$PID_FILE"

    set +e
    (export AWAKE_TEST_PMSET_FAIL_WRITE=1; runtime_signal_exit)
    local cleanup_status=$?
    set -e

    assert_equals "0" "$cleanup_status"
    [ -f "$BASELINE_FILE" ]
    [ -f "$OVERRIDE_MARKER_FILE" ]

    recover_power_state_on_launch
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
}

test_clean_signal_exit_does_not_request_restart() {
    setup_state clean-signal-exit
    mkdir -p "$DAEMON_LOCK_DIR"
    echo $$ > "$DAEMON_OWNER_FILE"
    echo $$ > "$PID_FILE"

    set +e
    (runtime_signal_exit)
    local signal_status=$?
    set -e

    assert_equals "0" "$signal_status"
    [ ! -f "$STATE_FILE" ]
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
}

test_launch_recovery_prunes_stale_timer_lease() {
    setup_state stale-timer-lease
    activate_nosleep >/dev/null
    lease_remove "manual-toggle"
    lease_create_or_update "manual-timer" "timer" "presenting" "Stale timer" 90 "" "cli"

    recover_power_state_on_launch

    [ ! -d "$LEASES_DIR/manual-timer" ]
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
}

test_launch_recovery_prunes_orphan_rule_lease() {
    setup_state orphan-rule-lease
    activate_nosleep >/dev/null
    lease_remove "manual-toggle"
    lease_create_or_update "rule-deleted-rule" "rule" "presenting" "Deleted rule" 60 "" "rule"

    recover_power_state_on_launch

    [ ! -d "$LEASES_DIR/rule-deleted-rule" ]
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
}

test_launch_recovery_prunes_stale_command_lease() {
    setup_state stale-command-lease
    activate_nosleep >/dev/null
    lease_remove "manual-toggle"
    lease_create_or_update "run-command" "command" "presenting" "Dead command" 85 "" "cli"
    echo 999999 > "$LEASES_DIR/run-command/owner_pid"

    recover_power_state_on_launch

    [ ! -d "$LEASES_DIR/run-command" ]
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
}

test_launch_recovery_prunes_malformed_manual_lease() {
    setup_state malformed-manual-lease
    activate_nosleep >/dev/null
    lease_remove "manual-toggle"
    mkdir -p "$LEASES_DIR/manual-toggle"

    recover_power_state_on_launch

    [ ! -d "$LEASES_DIR/manual-toggle" ]
    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
}

test_launch_recovery_ignores_unpublished_timer_process() {
    setup_state unpublished-timer
    activate_nosleep >/dev/null
    lease_remove "manual-toggle"
    sleep 30 &
    local timer_pid=$!
    echo "$timer_pid" > "$FOR_PID_FILE"
    echo "pending-token" > "$FOR_TOKEN_FILE"
    echo 9999999999 > "$FOR_END_FILE"

    recover_power_state_on_launch

    assert_equals "normal" "$(cat "$STATE_FILE")"
    assert_equals "0" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    kill "$timer_pid" 2>/dev/null || true
    rm -f "$FOR_PID_FILE" "$FOR_TOKEN_FILE" "$FOR_END_FILE"
}

test_launch_recovery_keeps_published_live_timer() {
    setup_state published-timer
    activate_nosleep >/dev/null
    lease_remove "manual-toggle"
    sleep 30 &
    local timer_pid=$!
    echo "$timer_pid" > "$FOR_PID_FILE"
    echo "live-token" > "$FOR_TOKEN_FILE"
    echo 9999999999 > "$FOR_END_FILE"
    lease_create_or_update "manual-timer" "timer" "presenting" "Live timer" 90 "" "cli" "$timer_pid"

    recover_power_state_on_launch

    [ -d "$LEASES_DIR/manual-timer" ]
    assert_equals "nosleep-full" "$(cat "$STATE_FILE")"
    assert_equals "1" "$(cat "$PMSET_STATE_DIR/disablesleep")"
    cancel_timer_session
    reconcile_effective_state
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
test_timer_replaces_existing_manual_session
test_timer_preserves_running_command_lease
test_background_reconcile_lock_uses_real_process_pid
test_timer_stays_awake_when_agents_active
test_manual_yessleep_cancels_timer
test_cancel_timer_command_clears_lease
test_replacing_timer_publishes_new_owner_atomically
test_timer_waits_until_agents_stop_before_restoring
test_restore_without_baseline_falls_back
test_launch_recovery_restores_after_crashed_daemon
test_reconcile_repairs_kernel_state_mismatch
test_launch_recovery_leaves_unowned_kernel_setting_alone
test_fix_clears_unowned_disablesleep
test_disablesleep_parsers_accept_real_mac_format
test_fix_noop_when_no_unowned_override
test_fix_releases_lock_when_pmset_fails
test_fix_refuses_to_clear_owned_session
test_fix_does_not_clear_while_reconcile_lock_held
test_unowned_disablesleep_surfaces_in_why
test_unowned_disablesleep_surfaces_in_warnings
test_fix_rechecks_ownership_after_acquiring_lock
test_failed_recovery_keeps_ownership_for_retry
test_runtime_signal_preserves_state_for_supervisor_restart
test_clean_signal_exit_does_not_request_restart
test_launch_recovery_prunes_stale_timer_lease
test_launch_recovery_prunes_orphan_rule_lease
test_launch_recovery_prunes_stale_command_lease
test_launch_recovery_prunes_malformed_manual_lease
test_launch_recovery_ignores_unpublished_timer_process
test_launch_recovery_keeps_published_live_timer
test_settings_apply_inactive
test_settings_apply_active_updates_baseline
test_settings_dump_json
test_temp_json

echo "timer and settings behavior tests passed"
