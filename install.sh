#!/bin/bash
# Awake installer. Run from the repository root.
set -euo pipefail

cd -- "$(dirname -- "$0")"
chmod +x awake awake-build-ui
./awake install
