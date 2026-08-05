# Security Policy

Report security issues privately to the repository owner. Include the affected version, reproduction steps, impact, and any known mitigation.

Awake runs without root privileges. It owns only its in-process macOS power assertions and releases them when a session stops, a timer expires, or the app exits. It does not change physical display brightness or system power settings.

Useful reports include command-mailbox injection, unsafe installer migration, assertion lifecycle bugs, and blackout recovery failures.
