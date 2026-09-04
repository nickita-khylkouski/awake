# Awake

Awake is a small macOS menu bar app that prevents idle system sleep, including when a MacBook lid is closed. Turn it on when you want your Mac to keep working; turn it off when you are done. Optional timers, display control, and closed-lid mode stay under your control. On battery power, Awake automatically requests sleep at 5% or below.

It has no daemon, agent watcher, lease system, resident privileged process, private display API, analytics, or updater. Closed-lid sessions call a small root-owned command that coordinates the system-wide setting across users and exits immediately.

## Install

Requires macOS 13 or newer.

```bash
npx --yes awake-agent install
```

For a local checkout:

```bash
./install.sh
```

The installer builds a universal Apple Silicon and Intel app at `~/.local/bin/Awake.app`, opens it, and starts an indefinite session. After that, use the sun or moon icon in the menu bar, or open Awake from the Dock. Left-click opens the control panel and right-click opens the quick menu. If a menu-bar organizer hides it, press `Control-Shift-A` or run `awake ui`.

## Menu

- One switch to start or stop keeping your Mac awake
- Start indefinitely, or for 15 minutes, 30 minutes, 1, 2, 4, or 8 hours
- Live battery level and automatic sleep protection at 5%
- Stop at any time
- Keep Display On is optional and off by default
- Keep Working With Lid Closed uses one administrator-approved power setting
- Black Out Screens covers every connected display with a black overlay
- Launch at Login uses the standard macOS login-item service

Press `Option-1` to toggle screen blackout. `Escape` also restores the screens. Blackout never changes physical monitor or keyboard brightness.

Selecting a timer while Awake is already on replaces the indefinite session with that deadline. The right-click quick menu also has a separate Extend action for an existing timer.

Timers use an absolute deadline and release the power assertion as soon as they reach zero. Ending a timer or turning Awake off allows normal sleep.

Battery protection is always enabled while the app is running, even with no active session. At 5% or below **on battery power**, Awake releases its assertions, restores its closed-lid override, restores blacked-out screens, then asks macOS to sleep using the public IOKit power API. It does not sleep merely because a charging battery is below 5%. A refused sleep request is retried, and new keep-awake sessions are blocked until power is connected or the battery rises above 5%. After a successful request, manually waking the Mac does not immediately put it back to sleep; reconnecting power or recovering above 5% arms the safeguard again. Quitting Awake also ends battery monitoring.

Closed-lid support changes only `pmset disablesleep` while at least one Awake user owns an active session. Awake restores the prior system value after the last session stops, on timer expiry, normal quit, uninstall, or the next launch after an interrupted session. It never changes sleep timers, standby, hibernation, or display brightness.

## CLI

```text
awake on
awake for 30m
awake until 17:30
awake off
awake nosleep-display
awake blackout
awake screens show
awake status --json
awake ui                    # Standalone controls
awake menu                  # Controls anchored to the menu-bar icon
```

The CLI delivers commands directly to Awake through LaunchServices, including during app startup. There is no shared command file or command polling loop. Status JSON includes the battery level and 5% protection state.

## Build and verify

```bash
npm test
./awake-build-ui
./package-app.sh
```

Local builds are ad-hoc signed. Public distribution still requires Apple Developer ID signing and notarization.
