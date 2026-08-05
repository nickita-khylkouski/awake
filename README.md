# Awake

Awake is a small macOS menu bar app that prevents idle system sleep. It has one native power assertion, an optional display assertion, reliable timers, and a reversible screen-blackout shortcut.

It has no daemon, agent watcher, lease system, privileged helper, private display API, analytics, or updater.

## Install

Requires macOS 13 or newer.

```bash
npx --yes awake-agent install
```

For a local checkout:

```bash
./install.sh
```

The installer builds a universal Apple Silicon and Intel app at `~/.local/bin/Awake.app`, opens it, and starts an indefinite session. After that, use the cup icon in the menu bar.

## Menu

- Start indefinitely, or for 15 minutes, 30 minutes, 1 hour, or 2 hours
- Stop at any time
- Keep Display On is optional and off by default
- Black Out Screens covers every connected display with a black overlay
- Launch at Login uses the standard macOS login-item service

Press `Option-1` to toggle screen blackout. `Escape` also restores the screens. Blackout never changes physical monitor or keyboard brightness.

Timers use an absolute deadline and release the power assertion as soon as they reach zero. Awake never forces the Mac to sleep. It only prevents or allows normal idle sleep.

macOS controls closed-lid sleep on MacBooks. Awake does not bypass it or change global `pmset` settings.

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
awake ui
```

The CLI writes a one-shot command to the running menu bar app. It does not start a background runtime.

## Build and verify

```bash
npm test
./awake-build-ui
./package-app.sh
```

Local builds are ad-hoc signed. Public distribution still requires Apple Developer ID signing and notarization.

![Awake information window](awake-screenshot.jpg)
