#!/bin/bash

set -euo pipefail

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/awake-updates-test.XXXXXX)"
STUB_BIN="$TEST_ROOT/bin"
TEST_HOME="$TEST_ROOT/home"
CALL_LOG="$TEST_ROOT/calls.log"
GLOBAL_PREFIX="$TEST_ROOT/global-prefix"
NPM_GLOBAL_DIR="$GLOBAL_PREFIX/lib/node_modules/awake-agent"
NPX_DIR="$TEST_ROOT/_npx/123/node_modules/awake-agent"
LOCAL_NODE_DIR="$TEST_ROOT/project/node_modules/awake-agent"
mkdir -p "$STUB_BIN" "$TEST_HOME/.config/awake" "$TEST_HOME/.local/bin" "$NPM_GLOBAL_DIR" "$NPX_DIR" "$LOCAL_NODE_DIR" "$GLOBAL_PREFIX/bin"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

cat > "$STUB_BIN/npx" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'npx %s\n' "$*" >> "${AWAKE_TEST_CALL_LOG:?}"
exit 0
EOF

cat > "$STUB_BIN/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "prefix" ] && [ "${2:-}" = "-g" ]; then
    printf '%s\n' "${AWAKE_TEST_NPM_PREFIX:?}"
    exit 0
fi
printf 'npm %s\n' "$*" >> "${AWAKE_TEST_CALL_LOG:?}"
exit 0
EOF

cat > "$GLOBAL_PREFIX/bin/awake" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'global-awake %s\n' "$*" >> "${AWAKE_TEST_CALL_LOG:?}"
exit 0
EOF

chmod +x "$STUB_BIN"/* "$GLOBAL_PREFIX/bin/awake"

cp "$REPO_DIR/awake" "$NPM_GLOBAL_DIR/awake"
cp "$REPO_DIR/package.json" "$NPM_GLOBAL_DIR/package.json"
cp "$REPO_DIR/awake" "$NPX_DIR/awake"
cp "$REPO_DIR/package.json" "$NPX_DIR/package.json"
cp "$REPO_DIR/awake" "$LOCAL_NODE_DIR/awake"
cp "$REPO_DIR/package.json" "$LOCAL_NODE_DIR/package.json"
chmod +x "$NPM_GLOBAL_DIR/awake" "$NPX_DIR/awake" "$LOCAL_NODE_DIR/awake"

export HOME="$TEST_HOME"
export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export AWAKE_TEST_CALL_LOG="$CALL_LOG"
export AWAKE_TEST_NPM_PREFIX="$GLOBAL_PREFIX"

LATEST_JSON="$TEST_ROOT/latest.json"
cat > "$LATEST_JSON" <<'EOF'
{"version":"9.9.9"}
EOF

assert_json() {
    local payload="$1"
    local script="$2"
    /usr/bin/python3 - "$payload" "$script" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
code = sys.argv[2]
ns = {"payload": payload}
exec(code, ns, ns)
PY
}

clear_calls() {
    : > "$CALL_LOG"
}

export AWAKE_UPDATE_REGISTRY_URL="file://$LATEST_JSON"

json="$("$REPO_DIR/awake" update status --refresh --json)"
assert_json "$json" '
assert payload["latestVersion"] == "9.9.9"
assert payload["installSource"] == "repo"
assert payload["canSelfUpdate"] is False
assert payload["updateAvailable"] is True
assert payload["source"] == "npm"
'
[ -f "$TEST_HOME/.config/awake/update-cache.json" ]

export AWAKE_UPDATE_REGISTRY_URL="file://$TEST_ROOT/missing.json"
json="$("$REPO_DIR/awake" update status --json)"
assert_json "$json" '
assert payload["latestVersion"] == "9.9.9"
assert payload["cached"] is True
assert payload["source"] == "npm"
'

rm -f "$TEST_HOME/.config/awake/update-cache.json"
json="$("$REPO_DIR/awake" update status --refresh --json)"
assert_json "$json" '
assert payload["latestVersion"] == payload["currentVersion"]
assert payload["updateAvailable"] is False
assert payload["error"]
'

export AWAKE_UPDATE_REGISTRY_URL="file://$LATEST_JSON"
repo_apply_output="$("$REPO_DIR/awake" update apply 2>&1 || true)"
printf '%s\n' "$repo_apply_output" | grep -Fq "Update from git"

json="$("$LOCAL_NODE_DIR/awake" update status --refresh --json)"
assert_json "$json" '
assert payload["installSource"] == "local-copy"
assert payload["canSelfUpdate"] is False
'

clear_calls
"$NPX_DIR/awake" update apply >/dev/null
grep -Fxq 'npx --yes awake-agent@latest install' "$CALL_LOG"
[ "$(wc -l < "$CALL_LOG")" -eq 1 ]

cat > "$LATEST_JSON" <<EOF
{"version":"$("$REPO_DIR/awake" version)"}
EOF
clear_calls
"$NPX_DIR/awake" update apply >/dev/null
[ ! -s "$CALL_LOG" ]

cat > "$LATEST_JSON" <<'EOF'
{"version":"9.9.9"}
EOF
clear_calls
"$NPM_GLOBAL_DIR/awake" update apply >/dev/null
grep -Fxq 'npm install -g awake-agent@latest' "$CALL_LOG"
grep -Fxq 'global-awake install' "$CALL_LOG"
[ "$(wc -l < "$CALL_LOG")" -eq 2 ]

echo "update tests passed"
