#!/bin/bash

set -euo pipefail

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/awake-setup-test.XXXXXX)"
STUB_BIN="$TEST_ROOT/bin"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$STUB_BIN" "$TEST_HOME/.claude" "$TEST_HOME/.codex" "$TEST_HOME/.local/bin"

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
exec "$@"
EOF

cat > "$STUB_BIN/pmset" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/powermetrics" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$STUB_BIN"/*

export HOME="$TEST_HOME"
export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

printf '{\n  "hooks": {}\n}\n' > "$TEST_HOME/.claude/settings.json"
touch "$TEST_HOME/.codex/config.toml"
printf '#!/bin/bash\nexit 0\n' > "$TEST_HOME/.local/bin/awake-hook"
printf '#!/bin/bash\nexit 0\n' > "$TEST_HOME/.local/bin/awake-notify"
chmod +x "$TEST_HOME/.local/bin/awake-hook" "$TEST_HOME/.local/bin/awake-notify"

assert_contains() {
    local needle="$1"
    local file="$2"
    if ! grep -Fq "$needle" "$file"; then
        echo "expected '$needle' in $file" >&2
        cat "$file" >&2
        exit 1
    fi
}

status_json="$("$REPO_DIR/awake" setup status-json)"
[[ "$status_json" == *'"sleepControlConfigured":true'* ]]
[[ "$status_json" == *'"temperatureConfigured":true'* ]]
[[ "$status_json" == *'"claudeDetected":true'* ]]
[[ "$status_json" == *'"claudeConfigured":false'* ]]
[[ "$status_json" == *'"codexDetected":true'* ]]
[[ "$status_json" == *'"codexConfigured":false'* ]]

"$REPO_DIR/awake" setup claude >/dev/null
"$REPO_DIR/awake" setup codex >/dev/null
"$REPO_DIR/awake" setup claude >/dev/null
"$REPO_DIR/awake" setup codex >/dev/null

assert_contains '"command": "'"$TEST_HOME"'/.local/bin/awake-hook claude"' "$TEST_HOME/.claude/settings.json"
assert_contains 'notify = "'"$TEST_HOME"'/.local/bin/awake-notify"' "$TEST_HOME/.codex/config.toml"

status_json="$("$REPO_DIR/awake" setup status-json)"
[[ "$status_json" == *'"claudeConfigured":true'* ]]
[[ "$status_json" == *'"codexConfigured":true'* ]]

echo "setup command tests passed"
