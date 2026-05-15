# Multi-Account Tracking & Lossless Account Switching

Date: 2026-04-20
Status: **Shipped** — merged to `main` as commits `4a3e379..7b9e698` on 2026-04-21. Smoke test confirmed end-to-end: 2 Claude accounts tracked simultaneously, menu switch swaps `Claude Code-credentials` at keychain level (account A ↔ account B), plugins/MCP install state untouched. Per-MCP OAuth re-auth still required per identity, as expected.

## Problem

ClaudeDock currently tracks a single Claude account (keychain entry
`Claude Code-credentials`) plus a single Codex identity (derived from
rollouts / `.omx/metrics.json`).

The user runs two Claude subscriptions and one Codex subscription.
Switching between Claude accounts today means running `/login` in
Claude Code, which overwrites the single keychain entry. Effects:

1. Only one Claude account's usage is visible at a time.
2. After each `/login`, MCP OAuth sessions tied to the previous
   identity (e.g. `claude.ai Google Drive`) are flagged for re-auth.
3. The user perceives this as "plugins lost" even though plugin
   install state (`installed_plugins.json`, `config.json`,
   `settings.json`) actually survives `/login` unchanged.

Goal:

- Track both Claude accounts + Codex simultaneously in the menu.
- Switch the active Claude identity without running `/login`, so the
  only thing that changes is the keychain blob. Plugins stay installed.
- Accept that MCP OAuth (Slack, Google Drive) is always re-auth per
  identity — explicitly out of scope.

## Empirical Verification Summary

A before/after snapshot around `/login` with a second account
(`scripts/snapshot_claude_auth.sh` + `diff_claude_auth.sh`) showed:

- Keychain: only `Claude Code-credentials` hash changes. No
  `plugin-*` / `claude-ai-*` / `mcp-*` services exist.
- `~/.claude/` file tree: no changes to `installed_plugins.json`,
  `config.json`, `blocklist.json`, `known_marketplaces.json`,
  `settings.json`.
- Only new artifact: `~/.claude/mcp-needs-auth-cache.json`, a hint
  file Claude Code writes to remember which MCP servers need
  re-authorization under the new identity.

Conclusion: the only state that must be preserved per-account is the
`Claude Code-credentials` blob itself.

## Design

### Storage Model

Per account, ClaudeDock maintains its own macOS keychain entry with
service name `ClaudeDock Account <label>` (e.g. `ClaudeDock Account
Work`). Blob contents = the exact JSON retrieved via `security
find-generic-password -s "Claude Code-credentials" -w` (hex-decoded
if needed). No re-encoding, no schema transformation. Refresh token,
access token, expires_at, subject, whatever Claude Code stores —
opaque passthrough.

The ClaudeDock app config at `~/.claude/claudedock.json` grows:

```jsonc
{
  "refreshInterval": 30,
  "activeAccountId": "work",
  "accounts": [
    { "id": "work",     "label": "Work",     "kind": "claude" },
    { "id": "personal", "label": "Personal", "kind": "claude" }
  ]
}
```

Codex is not represented in `accounts`; it remains a separate
always-on source derived from rollouts + `.omx/metrics.json` exactly
as today.

### Actions

1. **Save current login as…**
   - Read current `Claude Code-credentials` via `security
     find-generic-password`.
   - Prompt user for label (NSAlert with text field).
   - Write blob into `ClaudeDock Account <label>` with `security
     add-generic-password -U`.
   - Append entry to `accounts` list. Set `activeAccountId` to the
     new id.

2. **Switch active ▸ <label>**
   - Read `ClaudeDock Account <label>` blob.
   - Before first-ever switch, record the original
     `Claude Code-credentials` item's full attribute set (account
     name `-a`, access group, ACL / partition list) by running
     `security find-generic-password -s "Claude Code-credentials"`
     and preserving the `acct` value. Store alongside the account
     bundle as `originalAccountAttr`.
   - Write blob into `Claude Code-credentials` with `security
     add-generic-password -s "Claude Code-credentials" -a <acct>
     -U -w <blob>`. Preserving `-a` is required for Claude Code's
     read path to match the same item. If ACL/partition state is
     not preserved by `-U`, fall back to `delete-generic-password`
     followed by `add-generic-password` with explicit `-T /usr/bin/security`
     and re-prompt the user to allow access.
   - If `~/.claude/.credentials.json` exists (file fallback used
     by `KeychainReader.readFromFile`), also rewrite it with the
     new blob and restore `0600` perms. Keychain-only write is not
     enough if Claude Code prefers the file path on this install.
   - Update `activeAccountId` in config.
   - Show toast / menu note: "Restart `claude` CLI to pick up new
     login." No attempt to signal running Claude processes.

3. **Manage accounts ▸**
   - **Rename** — edits `label`; renames underlying keychain entry by
     copy + delete (macOS does not support in-place service rename).
   - **Delete** — removes keychain entry (`security
     delete-generic-password`) and the `accounts` entry. If it was
     active, clear `activeAccountId` (do not auto-pick another).

### Usage Polling

Refresh-token handling is **opportunistic, not core**. The design
must work even if the OAuth refresh endpoint / contract turns out to
be undocumented and unusable from a third-party app. In that case,
every account works until its access token expires (~8h) and then
surfaces `needsReLogin` until the user runs `/login` + "Save current
login as…" again. That is acceptable baseline behavior.

For each `accounts` entry (one loop per refresh interval):

1. Load blob from `ClaudeDock Account <label>`.
2. Parse `accessToken`, `refreshToken`, `expiresAt` from the blob
   (same JSON shape Claude Code writes: top-level `claudeAiOauth`
   object).
3. If `expiresAt - now < 60s`:
   - **Attempt** refresh via `OAuthRefresher` (best-effort).
   - On success: merge new tokens + expiry back into the blob and
     rewrite `ClaudeDock Account <label>`. If this account matches
     `activeAccountId`, also mirror the blob into
     `Claude Code-credentials` (and `.credentials.json` if present).
   - On failure: mark account `needsReLogin`; skip usage fetch.
     Do not retry the refresh until the user re-saves. Log the
     failure reason so we can diagnose what Anthropic requires
     (client binding, PKCE state, rotated refresh tokens, etc.)
     without breaking the user experience.
4. GET `https://api.anthropic.com/api/oauth/usage` with `Bearer
   <accessToken>` (same headers the current `UsageService` uses).
5. On 401/403: mark account `needsReLogin`.
6. On 429: apply the existing 5-minute backoff per account (cache
   the 429 timestamp in the per-account cache entry).
7. Parse response into the existing `UsageLimits` struct.

`OAuthRefresher` is isolated precisely so a future update can wire
the real refresh contract (or delete the module) without touching
the rest of the code.

Codex polling stays unchanged.

### Cache

Replace the current single-object cache at
`~/.claude/claudedock-cache.json` with a per-account map:

```jsonc
{
  "accounts": {
    "work":     { "data": { ...UsageLimits },
                  "timestamp": 1776670000000,
                  "backoff": false,
                  "error": null },
    "personal": { "data": null,
                  "timestamp": 1776670000000,
                  "backoff": false,
                  "error": "needsReLogin" }
  },
  "codex": { ...CodexMetrics },
  "timestamp": 1776670000000
}
```

On load, any cache lacking the `accounts` key is treated as legacy
and ignored (fresh fetch). No migration needed — worst case is one
stale minute after upgrade.

### Config Migration

`AppConfig` decoding today is all-or-nothing
(`UsageService.loadConfig`): any decode failure falls back to
`defaultConfig`, which would silently reset `refreshInterval` for
existing users upgrading to the multi-account schema.

Mitigation:

- `accounts` and `activeAccountId` are added as **optional** fields
  with safe defaults (`[]` and `nil`). Existing one-field configs
  continue to decode cleanly — only new fields default.
- Decoding uses a custom `init(from:)` that tolerates missing new
  fields rather than relying on Codable's strict synthesized init.
- On first successful run after upgrade, ClaudeDock writes the
  expanded config back to disk so subsequent reads are canonical.
- A corrupted config (JSON parse failure) still falls back to
  defaults, but logs the parse error so the user can see why their
  settings vanished.

### Active-Account Detection

- Primary: `activeAccountId` field in `claudedock.json`, written on
  every Switch and on Save.
- Fallback: if `activeAccountId` is missing or no longer valid,
  ClaudeDock hashes the current `Claude Code-credentials` blob and
  matches against each stored bundle. Match → set active.
  No match → leave `activeAccountId` unset; menu shows an "Unsaved
  login (Save as…)" row.

This covers the case where the user runs `/login` outside
ClaudeDock, picking up a new identity that ClaudeDock should offer
to save.

### Menu Layout

```
● Work (active) · 5h 42% · week 18%
○ Personal       · 5h 10% · week  5%
  Codex          · 5h 30% · week 12%
─────────────────────────
Switch active login ▸ Work / Personal
Save current login as…
Manage accounts ▸ Rename / Delete
─────────────────────────
Refresh now
Preferences…
Quit
```

Active account gets a filled-disc glyph; inactive gets hollow.
`needsReLogin` accounts render as `✕ <label> · re-login required`.

## Swift Changes

- **New** `AccountStore.swift` — thin wrapper around `security` CLI:
  `list()`, `load(label)`, `save(label, blob)`, `rename(old, new)`,
  `delete(label)`, plus `loadActive()` / `saveActive(blob)` for the
  `Claude Code-credentials` slot. Uses the same `/usr/bin/security`
  Process pattern already present in `KeychainReader`.
- **New** `AccountSwitcher.swift` — orchestrates Save / Switch /
  Rename / Delete, mutates `AppConfig`, invalidates
  `KeychainReader` cache (`clearCache`) so the next poll reads fresh.
- **New** `OAuthRefresher.swift` — performs refresh-token grant
  against Anthropic's OAuth endpoint. Encapsulates the endpoint URL
  and body shape in one place so it can be updated if Anthropic
  changes it. On failure returns a typed error that
  `UsageService` surfaces as `needsReLogin`.
- **Updated** `Models.swift` —
  - `AppConfig` gains `accounts: [AccountRef]`, `activeAccountId:
    String?`.
  - New `AccountRef { id, label, kind }`.
  - New `AccountUsage { account: AccountRef, limits: UsageLimits?,
    error: FetchError?, stale: Bool }`.
  - `FetchResult` becomes `{ accounts: [AccountUsage], codex:
    CodexMetrics?, refreshedAt: Date }`.
  - `CacheEntry` shape updated to the map above.
- **Updated** `UsageService.swift` — loops over accounts, handles
  refresh + backoff per account, retains existing Codex logic.
- **Updated** `KeychainReader.swift` — no longer the source of
  truth; becomes a helper that reads `Claude Code-credentials` for
  the "Save current login as…" action and for the hash-based active
  detection. Its single cached token is removed; per-account tokens
  are owned by `UsageService` + `AccountStore`.
- **Updated** `MenuBuilder.swift` — grouped rows per account,
  Switch submenu, Manage submenu, Save action. Active indicator.
- **Updated** `AppDelegate.swift` — wires new action handlers.

## Out of Scope

- MCP server OAuth preservation (Slack / Google Drive). These always
  re-auth per identity. `mcp-needs-auth-cache.json` is ignored.
- Hot-reloading creds into an already-running `claude` CLI. User
  restarts.
- Syncing accounts across machines. Local keychain only.
- Codex multi-account. Codex remains a single identity surfaced from
  file-based metrics.
- Custom OAuth flows inside ClaudeDock. The user still runs `/login`
  in Claude Code to obtain creds; ClaudeDock only captures the
  resulting keychain blob.

## Risks & Mitigations

- **Refresh endpoint shape unknown.** Anthropic's refresh URL /
  body is not part of a documented public API. Mitigation: isolate
  in `OAuthRefresher` so it can be adjusted without touching the
  rest; on refresh failure degrade to `needsReLogin` rather than
  crashing.
- **Keychain entry collisions.** User picks label "Work" twice.
  Mitigation: `AccountStore.save` refuses to overwrite an existing
  label; user must rename or delete first.
- **Cache format change.** Existing users have
  `claudedock-cache.json` in the old shape. Mitigation: on decode
  failure treat as empty, never crash.
- **Hash-based active detection false-negative.** If Claude Code
  rewrites the blob (e.g. after its own silent refresh) the hash
  stops matching any stored bundle. Mitigation: on mismatch,
  ClaudeDock refreshes its own copy of the matching account's blob
  by reading `Claude Code-credentials` when the user confirms
  `activeAccountId` still belongs to that account. Simpler
  alternative: on mismatch just leave `activeAccountId` as-is until
  the next Switch; stale hash is not a correctness problem.

## Pre-Implementation Spikes

Before the first line of Switch code ships, run these three spikes
to confirm assumptions the design rests on:

1. **Keychain attribute survival.** Dump the attributes of the
   existing `Claude Code-credentials` item (`security
   find-generic-password -s "Claude Code-credentials"`, note
   `acct`, `agrp`, ACL / partition list). Simulate a Switch with
   `add-generic-password -U` preserving those attrs and then
   attempt a read via the same code path Claude Code uses. If the
   read prompts for keychain access or fails, redesign the Switch
   to preserve ACL state (likely via delete + add with
   `-T /usr/bin/security` and `-T /Applications/ClaudeDock.app`).
2. **File fallback check.** Inspect whether the current Claude
   Code install has `~/.claude/.credentials.json` populated, and
   observe whether Claude Code prefers keychain or file when both
   exist. If file wins, Switch must write both (already specified).
3. **Refresh contract probe.** Attempt a refresh-token grant
   against a plausible Anthropic OAuth endpoint with a real
   expired token, capturing the response. Feed results back into
   `OAuthRefresher` implementation; if unsupported, ship with the
   best-effort path that always falls through to `needsReLogin`.

Spike results get appended to this spec as an appendix before the
writing-plans step turns the design into an implementation plan.

## Verification Artifacts

Preserved for future regressions:

- `scripts/snapshot_claude_auth.sh` — captures keychain service
  list, blob hashes, `~/.claude` file tree + auth-sensitive file
  hashes into `/tmp/claudedock-snap-<label>`.
- `scripts/diff_claude_auth.sh` — diffs two snapshots.

Re-run before shipping this feature to confirm the set of files
`/login` mutates has not grown.

## Appendix A — Spike Results (2026-04-20)

### A.1 Keychain attribute set

```
class: genp
attributes:
    "acct"<blob>="<unix-user>"              # local unix user, stable across Claude accounts
    "svce"<blob>="Claude Code-credentials"
    (no agrp, no visible ACL / partition_list in dump output)
```

### A.2 Switch mechanism that worked

`security add-generic-password -s "Claude Code-credentials" -a "<unix-user>" -U -w "$BLOB"`
— readback was byte-identical, Claude Code authenticated under the
restored identity with no `/login` prompt. Preserve `acct="<unix-user>"`
(or whatever the local unix user string is; read dynamically before
first switch).

Caveat: passing the blob via `-w "$BLOB"` on argv makes it visible
to `ps` during Process lifetime. Phase 2 `AccountStore.writePassword`
should write the blob via stdin or a 0600 temp file + `-w <path>` to
avoid the leak window.

### A.3 File fallback behavior

`~/.claude/.credentials.json` is absent on the current install;
Claude Code reads keychain only. `AccountSwitcher.mirrorFileFallbackIfPresent`
remains defensive for installs that do have the file.

### A.4 Refresh endpoint probe

- `https://console.anthropic.com/v1/oauth/token` exists (HTTP 400 with
  meaningful errors, not 404).
- JSON body → HTTP 400 `Invalid request format`.
- `application/x-www-form-urlencoded` body with
  `grant_type=refresh_token&refresh_token=<token>` but no client_id →
  HTTP 400 `Invalid request format`.
- Form body with `client_id=<fake-uuid>` → HTTP 400
  `Client with id ... not found`.

Conclusion: endpoint shape is form-encoded, `client_id` is required
and is whatever UUID Claude Code's OAuth app is registered under.
That UUID is not in the keychain blob and was not recovered in this
spike (would require reversing the Claude Code binary).

Implementation decision: ship `OAuthRefresher` with form-encoded
body, `client_id` left empty. Every refresh returns HTTP 400 →
fall through to `needsReLogin`. The module is isolated so a future
contribution can drop in the real `client_id` and enable refresh
without touching anything else.

### A.5 Branch

Implementation branch: `feat/multi-account`.
