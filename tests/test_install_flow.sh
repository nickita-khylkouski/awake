#!/bin/bash

set -euo pipefail

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/awake-install-test.XXXXXX)"
STUB_BIN="$TEST_ROOT/bin"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$STUB_BIN" "$TEST_HOME/.codex" "$TEST_HOME/.local/bin"

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

cat > "$STUB_BIN/xcode-select" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-p" ]; then
    echo /Applications/Xcode.app/Contents/Developer
    exit 0
fi
exit 0
EOF

cat > "$STUB_BIN/swiftc" <<'EOF'
#!/bin/bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        out="$2"
        shift 2
    else
        shift
    fi
done
[ -n "$out" ] || exit 1
mkdir -p "$(dirname "$out")"
printf '#!/bin/bash\nexit 0\n' > "$out"
chmod +x "$out"
EOF

cat > "$STUB_BIN/codesign" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/iconutil" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/sips" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/osascript" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/open" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$STUB_BIN/codex" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$STUB_BIN"/*

export HOME="$TEST_HOME"
export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

touch "$TEST_HOME/.codex/config.toml"

"$REPO_DIR/awake" install >/dev/null

[ -f "$TEST_HOME/.claude/settings.json" ]
grep -Fq "awake-hook claude" "$TEST_HOME/.claude/settings.json"
grep -Fq 'notify = "'"$TEST_HOME"'/.local/bin/awake-notify"' "$TEST_HOME/.codex/config.toml"
[ -f "$TEST_HOME/.local/bin/awake-package.json" ]
[ -f "$TEST_HOME/.config/awake/install-metadata.json" ]
grep -Fq '"packageName": "awake-agent"' "$TEST_HOME/.config/awake/install-metadata.json"
[ -f "$TEST_HOME/.local/bin/Awake.app/Contents/Resources/bin/awake-package.json" ]
[ -f "$TEST_HOME/.local/bin/Awake.app/Contents/Resources/ui/main.swift" ]

rm -f "$TEST_HOME/.local/bin/awake-package.json" "$TEST_HOME/.local/bin/AwakeApp/main.swift"
"$TEST_HOME/.local/bin/Awake.app/Contents/Resources/bin/awake" install >/dev/null
[ -f "$TEST_HOME/.local/bin/awake-package.json" ]
[ -f "$TEST_HOME/.local/bin/AwakeApp/main.swift" ]

echo "install flow tests passed"
