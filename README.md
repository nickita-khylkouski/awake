# awake

Keep your Mac alive while AI coding agents run. Prevents sleep — including lid-close sleep — as long as agents like Claude Code, Codex, Aider, Copilot, or Amp are active.

Unlike other keep-awake tools (Amphetamine, KeepingYouAwake, Caffeine), `awake` is **agent-aware**: it automatically activates when coding agents are detected and deactivates after a grace period when they stop.

## How it works

- Uses `pmset disablesleep 1` — the **only** way to prevent lid-close sleep on macOS
- Monitors running processes (`pgrep`) and hook heartbeat files (`/tmp/awake-claude-*`)
- Daemon polls every 15s, activates nosleep when agents detected, restores normal sleep after a grace period
- Battery-aware: force-sleeps at critical battery even if agents are running

## Features

| Feature | Description |
|---------|-------------|
| **Agent detection** | Auto-activates for claude, codex, aider, copilot, amp, opencode |
| **Hook heartbeats** | Claude Code hooks write `/tmp/awake-claude-*` files for accurate session tracking |
| **Lid-close prevention** | `pmset disablesleep 1` + `caffeinate` — works with lid closed |
| **Timed sessions** | `awake for 2h` — nosleep for a duration, then force-sleep |
| **Battery protection** | Warns at 15%, force-sleeps at 5% regardless of agents |
| **Display sleep mode** | Keep system awake but let the display turn off |
| **SwiftUI menu bar app** | SF Symbol icon, left-click toggle, right-click quick controls |
| **Launch agent** | Optional auto-start on login |
| **Notifications** | macOS notifications for state changes, battery warnings |

## Install

```bash
# 1. Copy the daemon script
cp awake ~/.local/bin/awake
chmod +x ~/.local/bin/awake

# 2. Set up passwordless sudo for pmset (required)
sudo visudo -f /etc/sudoers.d/pmset
# Add: your_username ALL=(ALL) NOPASSWD: /usr/bin/pmset

# 3. Install hooks + sudoers + launch agent
awake install

# 4. Build the menu bar app (requires Xcode command line tools)
cp awake-build-ui ~/.local/bin/awake-build-ui
chmod +x ~/.local/bin/awake-build-ui
mkdir -p ~/.local/bin/AwakeApp
cp ui/main.swift ~/.local/bin/AwakeApp/main.swift
awake-build-ui

# 5. Launch
awake start          # Start the daemon
open ~/.local/bin/Awake.app   # Open the menu bar app
```

## Usage

```bash
awake start              # Start daemon (backgrounds itself)
awake stop               # Stop daemon, restore normal sleep
awake nosleep            # Manual nosleep (full — display + system)
awake nosleep-display    # Nosleep but allow display to turn off
awake yessleep           # Restore normal sleep settings
awake for 2h             # Nosleep for 2 hours, then force-sleep
awake sleep              # Stop everything and sleep immediately
awake status             # Show current state
awake run <cmd>          # Keep awake while command runs
awake ui                 # Launch menu bar app
awake install            # Set up hooks, sudoers, launch agent
awake uninstall          # Remove everything
```

## Menu Bar App

The SwiftUI app provides:

- **Left-click** the icon → instantly toggles nosleep on/off
- **Right-click** → dropdown with status, agents, hooks, battery, timer controls, daemon controls
- **Icon**: green `⚡` when nosleep active (with uptime like `⚡ 2h`), gray `💤` when normal
- **Panel**: full dashboard with controls, settings, live log (toggle with `Ctrl+Shift+A`)

### Panel

- Hero section with animated status ring
- Agent and hook monitoring
- Nosleep ON/OFF, timer, daemon start/stop
- Display sleep toggle, launch agent toggle
- Live scrolling log

## Configuration

Copy `config.example` to `~/.config/awake/config` and edit:

```bash
AGENTS="claude codex aider copilot amp opencode"  # Processes to watch
POLL_INTERVAL=15        # Daemon poll interval (seconds)
GRACE_SECONDS=300       # Keep awake N seconds after last agent stops
BATTERY_CRITICAL=5      # Force sleep below this % (even with agents)
BATTERY_WARN=15         # Send notification below this %
```

## Claude Code Hook Integration

Add to your Claude Code hooks to signal active sessions:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "touch /tmp/awake-claude-$(echo $SESSION_ID | head -c 16)"
      }]
    }]
  }
}
```

The daemon detects these heartbeat files and keeps the Mac awake while sessions are active. Stale files (>2 min old) are automatically cleaned up.

## How it compares

| | awake | Amphetamine | KeepingYouAwake | Caffeine |
|---|---|---|---|---|
| Agent-aware auto-activate | ✅ | ❌ | ❌ | ❌ |
| Lid-close prevention | ✅ | ✅ | ❌ | ❌ |
| Hook heartbeats | ✅ | ❌ | ❌ | ❌ |
| Timed sessions | ✅ | ✅ | ✅ | ❌ |
| Battery force-sleep | ✅ | ✅ | ✅ | ❌ |
| CLI | ✅ | ❌ | ❌ | ❌ |
| Open source | ✅ | ❌ | ✅ | ❌ |
| Menu bar app | ✅ | ✅ | ✅ | ✅ |

## Requirements

- macOS 13+ (Ventura or later)
- Xcode command line tools (`xcode-select --install`)
- Passwordless sudo for `pmset`

## License

MIT
