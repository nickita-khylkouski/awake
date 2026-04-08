# Contributing to awake

Thanks for contributing.

## Project shape

`awake` is intentionally narrow:

- one Bash runtime/CLI in `awake`
- one native macOS menu bar app in `ui/main.swift`
- shell-based regression tests in `tests/`

Please keep that shape unless there is a strong reason to add complexity.

## Development setup

```bash
git clone https://github.com/nickita-khylkouski/awake.git
cd awake
./install.sh
```

For local iteration:

```bash
./awake install
open ~/.local/bin/Awake.app
```

## Before opening a PR

Run the relevant checks:

```bash
npm run verify:shell
bash tests/test_setup_commands.sh
bash tests/test_timer_behavior.sh
bash tests/test_leases.sh
bash tests/test_modes.sh
bash tests/test_rules.sh
bash tests/test_status_json.sh
bash tests/test_build_ui.sh
bash tests/test_install_flow.sh
swiftc -typecheck ui/main.swift
```

At minimum:
- shell/runtime changes should include or update regression tests
- UI-only changes should still pass `swiftc -typecheck ui/main.swift`
- install/build changes should be verified with the install/build tests

## Pull request guidance

Good PRs for `awake` are:

- narrow in scope
- explicit about user-facing behavior changes
- clear about daemon/runtime risk
- backed by a short validation list

Please include:
- what changed
- why it changed
- how you tested it
- any remaining caveats

## Product bar

Changes should make one of these meaningfully better:

- reliability of sleep control
- clarity of the menu bar experience
- setup/onboarding quality
- agent-aware automation
- safe restore behavior

Avoid adding broad “power utility” scope that is not clearly in service of agent workflows.
