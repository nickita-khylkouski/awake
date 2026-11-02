# Contributing to Awake

Keep Awake small. The product is one native menu bar app, one CLI bridge, and one build script.

Before opening a pull request, run:

```bash
npm test
./package-app.sh
npm pack --dry-run
```

Changes must preserve these properties:

- no daemon, agent watcher, lease system, resident privileged process, or private framework
- the root-owned power command is short-lived and may only coordinate `pmset disablesleep`; no privileged forced-sleep command
- battery protection requests sleep only for a valid internal-battery reading at 5% or below on battery power, after releasing Awake-owned overrides
- timer expiry always releases the app-owned assertion at zero
- blackout is overlay-only and restores only with `Option-1` or app termination
- builds target macOS 13 and contain both `arm64` and `x86_64`

Prefer removing code over adding another background mechanism.
