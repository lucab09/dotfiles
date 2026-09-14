#!/usr/bin/env bash
# Install snapshots, not symlinks into a possibly temporary worktree.
set -euo pipefail
PI_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$PI_SOURCE/workflow/install.py" "$@"
