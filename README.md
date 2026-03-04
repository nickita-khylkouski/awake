# awake

Keep your Mac alive while AI coding agents run. Prevents sleep — including lid-close sleep — as long as agents like Claude Code, Codex, Aider, Copilot, or Amp are detected.

Unlike other keep-awake tools (Amphetamine, KeepingYouAwake, Caffeine), `awake` is **agent-aware**: it automatically activates when coding agents are detected and goes back to normal sleep after a configurable grace period when they stop.

## Why this exists

When you run AI coding agents (Claude Code, Codex CLI, Aider, etc.) on a laptop, they need the machine to stay awake — sometimes for hours. Close the lid to grab coffee, and your agent dies mid-task. macOS energy settings can prevent idle sleep, but **nothing in System Settings prevents lid-close sleep**. The only way is `sudo pmset disablesleep 1`, and you need something to manage that automatically.

`awake` watches for running agents, activates lid-close prevention when they're detected, handles battery protection so your laptop doesn't die, and cleans up when agents stop.

## How it works

```
┌─────────────────────────────────────────────────────┐
│                    awake daemon                      │
│                                                      │
│  every 15s:                                          │
│    1. pgrep for agent processes                      │
│    2. check /tmp/awake-claude-* heartbeat files      │
│    3. if agents found:                               │
│         → sudo pmset disablesleep 1                  │
│         → caffeinate -disu (backup assertion)        │
│         → write "nosleep-full" to /tmp/awake-state   │
│    4. if no agents for GRACE_SECONDS (default 5min): │
│         → sudo pmset disablesleep 0                  │
│         → kill caffeinate                            │
│         → write "normal" to /tmp/awake-state         │
│    5. if battery < BATTERY_CRITICAL (default 5%):    │
│         → force sleep regardless of agents           │
└─────────────────────────────────────────────────────┘
```

### Two layers of sleep prevention

1. **`pmset disablesleep 1`** — kernel-level flag. The *only* way to prevent sleep when the lid is closed. Requires passwordless sudo.
2. **`caffeinate -disu`** — creates IOPMAssertion to prevent idle sleep, display sleep, system sleep, and user-idle sleep. Belt and suspenders.

### Agent detection

The daemon detects agents two ways:

- **Process detection**: `pgrep -x claude`, `pgrep -x codex`, `pgrep -x aider`, etc. Works for any agent that runs as a named process.
- **Hook heartbeats**: Claude Code sessions write timestamped files to `/tmp/awake-claude-<session-id>`. The daemon checks file modification times — if a file was touched in the last 2 minutes, that session is active. More accurate than process counting since Claude Code spawns many subprocesses.

### State machine

```
             agents detected
  [normal] ──────────────────→ [nosleep-full]
     ↑                              │
     │    grace period expired      │
     │    (no agents for 5min)      │
     └──────────────────────────────┘

  At any point: battery < 5% → force sleep
```

State is stored in `/tmp/awake-state` so the menu bar app and CLI can read it without IPC.

## Prerequisites

Before installing, you need:

1. **macOS 13 (Ventura) or later** — required for the SwiftUI menu bar app (SF Symbols, modern SwiftUI APIs)
2. **Xcode Command Line Tools** — needed to compile the Swift menu bar app
   ```bash
   xcode-select --install
   ```
3. **Passwordless sudo for pmset** — the daemon needs to run `sudo pmset` without a password prompt

## Install

### Step 1: Clone the repo

```bash
git clone https://github.com/nickita-khylkouski/awake.git
cd awake
```

### Step 2: Set up passwordless sudo for pmset

This is required. Without it, the daemon can't change sleep settings.

```bash
# Option A: Use the install command (it will tell you what to do)
# Option B: Do it manually:
sudo bash -c 'echo "$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/pmset" > /etc/sudoers.d/pmset'
sudo chmod 440 /etc/sudoers.d/pmset
```

Verify it works:
```bash
sudo -n pmset -g    # Should print settings without asking for password
```

### Step 3: Copy files to ~/.local/bin

```bash
mkdir -p ~/.local/bin
cp awake ~/.local/bin/awake
cp awake-build-ui ~/.local/bin/awake-build-ui
chmod +x ~/.local/bin/awake ~/.local/bin/awake-build-ui

mkdir -p ~/.local/bin/AwakeApp
cp ui/main.swift ~/.local/bin/AwakeApp/main.swift
```

Make sure `~/.local/bin` is on your PATH. Add to your `~/.zshrc` if needed:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Step 4: Build the menu bar app

```bash
awake-build-ui
```

This compiles `main.swift` into `~/.local/bin/Awake.app` — a standalone macOS app bundle with no dependencies.

### Step 5: Run the install command

```bash
awake install
```

This does:
- Creates `~/.config/awake/config` with default settings
- Builds the menu bar app (if source exists)
- Patches Claude Code `~/.claude/settings.json` to add heartbeat hooks (if Claude Code is installed)
- Patches Codex `~/.codex/config.toml` notification (if Codex is installed)
- Warns if sudoers isn't set up

### Step 6: Start

```bash
awake start              # Start the daemon
open ~/.local/bin/Awake.app   # Open the menu bar app (optional)
```

### Optional: Auto-start on login

Toggle in the menu bar app settings, or manually:
```bash
# The app has a "Start at login" toggle that creates a LaunchAgent.
# Or from the CLI:
cat > ~/Library/LaunchAgents/com.awake.daemon.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.awake.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/.local/bin/awake</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
# Replace YOUR_USERNAME, then:
launchctl load ~/Library/LaunchAgents/com.awake.daemon.plist
```

## Uninstall

```bash
awake uninstall    # Removes hooks from Claude Code/Codex, restores sleep settings
awake stop         # Stop the daemon

# Then delete files:
rm -rf ~/.local/bin/awake ~/.local/bin/awake-build-ui ~/.local/bin/AwakeApp ~/.local/bin/Awake.app
rm -rf ~/.config/awake
rm -f ~/Library/LaunchAgents/com.awake.daemon.plist
rm -f /tmp/awake-*
sudo rm -f /etc/sudoers.d/pmset
```

## Usage

### CLI commands

```bash
awake start              # Start daemon (backgrounds itself, polls for agents)
awake stop               # Stop daemon, kill caffeinate, restore normal sleep
awake status             # Show current state, agents, battery, hooks

awake nosleep            # Manual nosleep (full — prevents all sleep including lid-close)
awake nosleep-display    # Nosleep but allow display to turn off (saves power)
awake yessleep           # Restore normal sleep settings manually

awake for 2h             # Nosleep for 2 hours, then force-sleep
awake for 30m            # Nosleep for 30 minutes
awake sleep              # Stop everything and put the Mac to sleep immediately

awake run <cmd>          # Keep awake while <cmd> runs, then restore sleep
awake ui                 # Launch the menu bar app
awake install            # Set up hooks, config, build UI
awake uninstall          # Remove hooks, clean up
```

### Menu bar app

The SwiftUI menu bar app shows an icon in your menu bar:

- **Green bolt icon** (`⚡ 2h`) — nosleep is active, showing how long
- **Moon icon** — normal sleep mode

**Interactions:**
- **Left-click** → instantly toggles nosleep on/off (no menu, no confirmation)
- **Right-click** → opens dropdown with:
  - Status (nosleep/normal, uptime)
  - Active agents (claude(5), codex(2), etc.)
  - Active hooks (session IDs with age)
  - Battery percentage
  - Timer remaining
  - Nosleep ON / Sleep OK toggle
  - Timer submenu (15m, 30m, 1h, 2h, 4h, 8h, cancel)
  - Start/Stop Daemon
  - Open Panel, Sleep Now, Quit

**Panel** (toggle with `Ctrl+Shift+A` or right-click → Open Panel):
- Full dashboard with hero status, pulsing animation when active
- Agent and hook monitoring
- All controls: nosleep toggle, timer, daemon start/stop, sleep now
- Settings: display sleep toggle, start at login toggle
- Live scrolling log of all state changes

## Configuration

Copy `config.example` to `~/.config/awake/config`:

```bash
mkdir -p ~/.config/awake
cp config.example ~/.config/awake/config
```

Edit `~/.config/awake/config`:

```bash
# Which process names to watch (space-separated)
AGENTS="claude codex aider copilot amp opencode"

# How often the daemon checks for agents (seconds)
POLL_INTERVAL=15

# After the last agent stops, keep nosleep active for this long (seconds)
# Prevents sleep during brief pauses between agent runs
GRACE_SECONDS=300

# Force sleep when battery drops below this % (even if agents are running)
BATTERY_CRITICAL=5

# Send a macOS notification when battery drops below this %
BATTERY_WARN=15
```

### Adding custom agents

To watch for additional processes (e.g., Docker, a custom script):

```bash
AGENTS="claude codex aider copilot amp opencode docker my-custom-agent"
```

The daemon runs `pgrep -x <name>` for each, so the name must match the process name exactly.

## Claude Code hook integration

For the most accurate agent detection, set up heartbeat hooks. The `awake install` command does this automatically, but here's how it works:

Claude Code supports [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) — shell commands that run on events like tool use. Add a hook that touches a file on every tool use:

**In `~/.claude/settings.json`:**
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "touch /tmp/awake-claude-$(echo $SESSION_ID | head -c 16)",
            "timeout": 3
          }
        ]
      }
    ]
  }
}
```

This creates/updates a file per session. The daemon checks modification times — if a file was touched in the last 2 minutes, that session is considered active. Files older than 2 minutes are cleaned up automatically.

**Why hooks instead of just pgrep?** Claude Code spawns many processes (`claude`, node workers, etc.). Hook heartbeats tell you which sessions are *actually doing work* vs. idle in the background.

## File layout

```
~/.local/bin/
  awake                  # Daemon + CLI script (bash)
  awake-build-ui         # Build script for the Swift app
  AwakeApp/
    main.swift           # SwiftUI menu bar app source
  Awake.app/             # Compiled app bundle (created by awake-build-ui)
    Contents/
      MacOS/AwakeUI      # Binary
      Info.plist

~/.config/awake/
  config                 # User configuration

/tmp/
  awake-state            # Current state: "nosleep-full", "nosleep-display", or "normal"
  awake.pid              # Daemon PID
  awake-caffeinate.pid   # caffeinate process PID
  awake-for.pid          # Timer subprocess PID (when using "awake for")
  awake-for-end          # Timer end epoch (for countdown display)
  awake-last-active      # Epoch of last detected agent activity
  awake-display-sleep    # Exists if display-sleep mode is enabled
  awake-claude-*         # Heartbeat files from Claude Code hooks
  awake-codex-*          # Heartbeat files from Codex hooks

~/Library/LaunchAgents/
  com.awake.daemon.plist # Optional: auto-start on login
```

## Troubleshooting

### "sudo pmset failed" error
Passwordless sudo isn't set up. Run:
```bash
sudo bash -c 'echo "$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/pmset" > /etc/sudoers.d/pmset'
sudo chmod 440 /etc/sudoers.d/pmset
```

### Daemon starts but Mac still sleeps on lid close
Check that `disablesleep` is set:
```bash
sudo pmset -g | grep disablesleep
# Should show: disablesleep 1
```
If it shows 0, something is resetting it. Check if another tool (Amphetamine, etc.) is conflicting.

### Menu bar icon doesn't appear
On MacBooks with a notch, the menu bar has limited space. If too many icons are present, macOS silently hides new ones. Try:
- Quit other menu bar apps to free space
- Use a menu bar manager like [Ice](https://github.com/jordanbaird/Ice) to manage visibility
- The panel still works via `Ctrl+Shift+A` even without the icon

### Orphaned caffeinate processes
If you see multiple `caffeinate` processes:
```bash
ps aux | grep caffeinate
```
Run `awake yessleep && awake nosleep` — this kills all orphaned caffeinate processes and starts a fresh one.

### Timer expired but Mac didn't sleep
The timer checks if agents are still running before force-sleeping. If agents are active when the timer expires, it stays awake and logs a message instead.

### "Action timed out (auto-reset)" in the log
The menu bar app has a safety mechanism: if an action (like toggling nosleep) takes longer than 20 seconds, it auto-resets the busy state. This prevents the UI from getting stuck with disabled buttons.

### Build fails with "no such module"
Make sure Xcode Command Line Tools are installed:
```bash
xcode-select --install
```

### Desktop Mac (no battery)
Works fine — battery monitoring is skipped, the app shows "AC (desktop)" instead. All other features work normally.

## How it compares

| | awake | Amphetamine | KeepingYouAwake | Caffeine |
|---|---|---|---|---|
| Agent-aware auto-activate | yes | no | no | no |
| Lid-close prevention | yes | yes | no | no |
| Hook heartbeats | yes | no | no | no |
| Grace period | yes | no | no | no |
| Battery force-sleep | yes | yes | yes | no |
| Timed sessions | yes | yes | yes | no |
| CLI control | yes | no | no | no |
| Display-only sleep mode | yes | yes | no | no |
| Open source | yes | no | yes | no |
| Menu bar app | yes | yes | yes | yes |
| Process-based triggers | yes (agents) | yes (any app) | no | no |

## Requirements

- macOS 13+ (Ventura or later)
- Xcode Command Line Tools (`xcode-select --install`)
- Passwordless sudo for `/usr/bin/pmset`
- bash (ships with macOS)

## License

MIT
