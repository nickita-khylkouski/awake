# Security Policy

If you find a security issue in `awake`, please do not open a public GitHub issue with exploit details.

Report it privately to the repository owner first. Include:

- affected version or commit
- reproduction steps
- impact
- any mitigation you already know

Areas worth reporting:

- unsafe `sudo` or `pmset` handling
- install-time config mutation issues
- hook integration vulnerabilities
- command injection or shell quoting bugs
- privilege or persistence bugs in login/startup behavior

This project manages local power behavior and setup integrations, so conservative disclosure is preferred.
