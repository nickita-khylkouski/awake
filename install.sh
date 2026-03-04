#!/bin/bash
# awake installer — run from the repo root: ./install.sh
set -euo pipefail

BIN="$HOME/.local/bin"
APP_SRC="$BIN/AwakeApp"

echo "[awake] Installing..."

# 1. Create directories
mkdir -p "$BIN" "$APP_SRC" "$HOME/.config/awake"

# 2. Copy files
cp awake "$BIN/awake"
cp awake-build-ui "$BIN/awake-build-ui"
cp ui/main.swift "$APP_SRC/main.swift"
chmod +x "$BIN/awake" "$BIN/awake-build-ui"

# 3. Create config if missing
if [ ! -f "$HOME/.config/awake/config" ]; then
    cp config.example "$HOME/.config/awake/config"
    echo "[awake] Created config at ~/.config/awake/config"
fi

# 4. Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "$BIN"; then
    echo ""
    echo "[awake] WARNING: $BIN is not on your PATH"
    echo "        Add this to your ~/.zshrc:"
    echo "        export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# 5. Check sudoers
if ! sudo -n pmset -g >/dev/null 2>&1; then
    echo ""
    echo "[awake] Passwordless sudo for pmset is not set up."
    echo "        Run this command:"
    echo "        sudo bash -c 'echo \"$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/pmset\" > /etc/sudoers.d/pmset && chmod 440 /etc/sudoers.d/pmset'"
    echo ""
fi

# 6. Check Xcode CLI tools
if ! xcode-select -p >/dev/null 2>&1; then
    echo "[awake] Xcode Command Line Tools not found. Install with:"
    echo "        xcode-select --install"
    echo ""
else
    # 7. Build the menu bar app
    echo "[awake] Building menu bar app..."
    "$BIN/awake-build-ui"
fi

# 8. Run awake install (hooks, etc.)
"$BIN/awake" install

echo ""
echo "[awake] Done! Next steps:"
echo "  1. Set up passwordless sudo (if not done — see above)"
echo "  2. awake start             # start the daemon"
echo "  3. open ~/.local/bin/Awake.app  # open menu bar app"
