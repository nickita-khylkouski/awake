# Security Policy

Report security issues privately to the repository owner. Include the affected version, reproduction steps, impact, and any known mitigation.

Awake itself runs without root privileges. Closed-lid mode installs a root-owned `awake-power` command plus a per-user sudoers rule for exactly `awake-power on <uid>` and `awake-power off <uid>`. The command coordinates the system-wide value across users and exits immediately; no privileged helper stays running. It records the prior value before the first session and restores it after the final session stops, a timer expires, the app exits, or the app next launches after an interrupted session.

Closing a MacBook while it is working can trap heat. Keep it ventilated and never put it in a bag while closed-lid mode is active. Screen blackout is an overlay and does not change physical display or keyboard brightness.

Battery protection uses the public `IOPMSleepSystem` API as the console user, after releasing Awake assertions and its closed-lid override. It needs no additional administrator permission. Invalid or external power-source readings never trigger sleep.

Useful reports include command validation, unsafe installer migration, assertion lifecycle bugs, and blackout recovery failures.
