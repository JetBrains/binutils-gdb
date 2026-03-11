#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

UPSTREAM_URL="git://sourceware.org/git/binutils-gdb.git"

# Add upstream remote
if git -C "$REPO_ROOT" remote get-url upstream >/dev/null 2>&1; then
    echo "upstream remote already configured: $(git -C "$REPO_ROOT" remote get-url upstream)"
else
    git -C "$REPO_ROOT" remote add upstream "$UPSTREAM_URL"
    echo "Added upstream remote: $UPSTREAM_URL"
fi

# Fetch upstream tags (GDB release points used as base refs by apply.sh)
echo "Fetching upstream tags..."
git -C "$REPO_ROOT" fetch upstream --tags --no-recurse-submodules
echo "Done."

echo
echo "Available GDB release tags:"
git -C "$REPO_ROOT" tag -l 'gdb-*-release' | sort -V | tail -5
