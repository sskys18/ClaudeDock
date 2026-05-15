# Live-slot reconciliation + UI strip-down

Date: 2026-04-22
Status: **Shipped** — main `939b48f..HEAD`.

## Problem

Post multi-account rollout surfaced four defects:

1. **Fresh login invisible.** A user `/login`'d but hadn't clicked "Save
   current login as…" saw no row in the menu. `UsageService` only
   iterated `config.accounts`.
2. **Active account stale after external refresh.** `fetchOne` always
   read the saved bundle, not the live `Claude Code-credentials` slot.
   When the Claude CLI refreshed its token, the app kept hitting the
   endpoint with the stale saved token and returned `needsReLogin`.
3. **OAuth refresh one-way.** Refreshed blobs were written back to the
   saved bundle only — never to the live slot — so the CLI ran on an
   expiring token.
4. **Backoff lock-in.** Each refresh tick rewrote the per-account cache
   timestamp even when the tick short-circuited on backoff, so the
   backoff window never closed and data froze at whatever value was
   cached when the first 429 hit.

Also requested: strip the account-management UI (Save / Switch /
Manage), punch up row legibility.

## Fix

### UsageService (live reconciliation)

- Trust `config.activeAccountId` as the declaration of which saved
  account represents the live keychain slot. Blob-equality matching was
  tried first and abandoned — Anthropic's access token is an opaque
  108-char string (not JWT), so there is no stable per-account
  identifier inside the blob, and rotating tokens cause false splits.
- When fetching, read the live blob once via `readClaudeCodeBlob()`. For
  the active account, use the live blob and proactively overwrite the
  saved bundle to keep them aligned.
- When `activeAccountId` is nil/unknown and a live blob exists, prepend
  a synthetic `Current login` row (id `__current__`). This row is
  excluded from any account-management code paths.
- On OAuth refresh success, write the new blob to both the saved bundle
  and — if the account is live — the `Claude Code-credentials` slot.

### UsageService (backoff)

- Backoff gate moved from `fetchOne` into `fetchUsage`. The short-circuit
  path no longer writes the cache entry, so the cache timestamp only
  advances on real API attempts. Backoff windows now genuinely expire
  (`backoffSeconds = 120`).
- `↻ Refresh` menu action calls `clearBackoffs()` before refreshing.
- Non-200 responses log status, `Retry-After`, and
  `anthropic-ratelimit-*` headers to stderr for diagnosis.

### MenuBuilder

- Removed account-management items (Save / Switch / Manage). Config is
  now edited directly in `~/.claude/claudedock.json` + keychain.
- Row format: `[dot] Label\t[colored dot] NN% countdown\t[colored dot] NN% countdown`.
- Bolder percent, brighter inactive label, larger fonts (row 13pt,
  small 11.5pt medium) for legibility.
- 50–80% threshold switched from yellow to orange.
- Codex row uses a purple `◆` prefix to distinguish from account rows.

## Out of scope

- Stable per-account identity inside the blob (would need Anthropic to
  expose a `user_id` or ship the public OAuth `client_id` for refresh).
- Automatic recovery when the user re-auths externally as a different
  account while `activeAccountId` still points at the old saved bundle.
  Current behavior: the saved bundle will be silently overwritten. The
  caveat is documented in README; the mitigation is "only mark an
  account active when you intend it to own the live slot".
