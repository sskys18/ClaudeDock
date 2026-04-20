#!/usr/bin/env bash
# Snapshot Claude auth-related state for before/after /login comparison.
# Usage: scripts/snapshot_claude_auth.sh <label>
#   label: "before" or "after" (or any tag)
# Output: /tmp/claudedock-snap-<label>/

set -u
LABEL="${1:-snap}"
OUT="/tmp/claudedock-snap-${LABEL}"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "Snapshotting to $OUT"

# 1. Keychain: list services matching our patterns + their blobs (SHA only for privacy)
{
  security dump-keychain 2>/dev/null \
    | awk -F'"' '/"svce"<blob>=/ { print $4 }' \
    | grep -iE 'claude|plugin|mcp|anthropic|slack|google|drive|openai|codex' \
    | sort -u
} > "$OUT/keychain-services.txt"

# For each matched service, record the md5 of its secret blob (so we can tell if it changed without leaking the secret)
> "$OUT/keychain-hashes.txt"
while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  blob=$(security find-generic-password -s "$svc" -w 2>/dev/null || echo "")
  if [[ -n "$blob" ]]; then
    h=$(printf '%s' "$blob" | md5)
    printf '%s\t%s\n' "$h" "$svc" >> "$OUT/keychain-hashes.txt"
  else
    printf 'MISSING\t%s\n' "$svc" >> "$OUT/keychain-hashes.txt"
  fi
done < "$OUT/keychain-services.txt"

# 2. ~/.claude file tree (names + sizes + mtimes, excluding noise)
find "$HOME/.claude" -maxdepth 4 -type f \
  \! -path "*/projects/*" \
  \! -path "*/sessions/*" \
  \! -path "*/history*" \
  \! -path "*/cache/*" \
  \! -path "*/telemetry/*" \
  \! -path "*/usage-data/*" \
  \! -path "*/statsig/*" \
  \! -path "*/file-history/*" \
  \! -path "*/todos/*" \
  \! -path "*/transcripts/*" \
  \! -path "*/paste-cache/*" \
  \! -path "*/debug/*" \
  \! -path "*/shell-snapshots/*" \
  \! -path "*/backups/*" \
  \! -path "*/tasks/*" \
  \! -path "*/session-env/*" \
  -exec stat -f '%N %z %m' {} \; 2>/dev/null \
  | sort > "$OUT/claude-tree.txt"

# 3. Hashes of specific auth-sensitive files (if present)
> "$OUT/file-hashes.txt"
for f in \
  "$HOME/.claude/.credentials.json" \
  "$HOME/.claude/plugins/installed_plugins.json" \
  "$HOME/.claude/plugins/config.json" \
  "$HOME/.claude/plugins/blocklist.json" \
  "$HOME/.claude/plugins/known_marketplaces.json" \
  "$HOME/.claude/settings.json" \
  "$HOME/.claude/settings.local.json"
do
  if [[ -f "$f" ]]; then
    h=$(md5 -q "$f")
    printf '%s\t%s\n' "$h" "$f" >> "$OUT/file-hashes.txt"
  else
    printf 'MISSING\t%s\n' "$f" >> "$OUT/file-hashes.txt"
  fi
done

# 4. Plugins data dir contents (structural, not secrets)
find "$HOME/.claude/plugins/data" -maxdepth 3 -type f \
  -exec stat -f '%N %z' {} \; 2>/dev/null \
  | sort > "$OUT/plugins-data-tree.txt"

echo "Done. Snapshot at $OUT"
