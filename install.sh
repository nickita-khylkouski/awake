#!/bin/bash
# awake installer — run from the repo root: ./install.sh
set -euo pipefail

cd -- "$(dirname -- "$0")"
chmod +x awake awake-build-ui awake-build-icon awake-hook awake-notify
./awake install
