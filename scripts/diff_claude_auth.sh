#!/usr/bin/env bash
# Diff two snapshots taken by snapshot_claude_auth.sh
# Usage: scripts/diff_claude_auth.sh before after
set -u
A="/tmp/claudedock-snap-${1:-before}"
B="/tmp/claudedock-snap-${2:-after}"

for f in keychain-services.txt keychain-hashes.txt claude-tree.txt file-hashes.txt plugins-data-tree.txt; do
  echo "=================================================="
  echo "DIFF: $f"
  echo "=================================================="
  diff -u "$A/$f" "$B/$f" || true
done
