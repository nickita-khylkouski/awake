# Contributing to Awake

Keep Awake small. The product is one native menu bar app, one CLI bridge, and one build script.

Before opening a pull request, run:

```bash
npm test
./package-app.sh
npm pack --dry-run
```

Changes must preserve these properties:

- no daemon, agent watcher, lease system, privileged helper, or private framework
- no global `pmset` mutation or forced-sleep command
- timer expiry always releases the app-owned assertion at zero
- blackout is overlay-only and restores with `Option-1`, `Escape`, or app termination
- builds target macOS 13 and contain both `arm64` and `x86_64`

Prefer removing code over adding another background mechanism.
