# Session Handoff
> Generated: 2026-05-15

## Task

ClaudeDock — wire manual account-switch UI (backend existed but UI never invoked it), then layer 5h/7d quota-based auto-rotation policy.

## Status

### Completed (Fix 1 — manual switch UI)

- **Diagnosed root cause**: `AccountSwitcher.switchTo()` was dead code. Zero call sites from UI. `MenuBuilder.buildAccountRow` rendered cards with `isEnabled = false` and no target/action.
- **Verified swap mechanism** end-to-end via `security` CLI (Test A): wrote a stored slot blob → live `Claude Code-credentials` slot → verified equality → auto-restored. Mechanism sound; only UI missing.
- **Verified identity via Anthropic `/api/oauth/profile`** for live + each stored slot. Confirmed labels matched real accounts.
- **Implemented Fix 1**:
  - `MenuBuilder.swift`: extended `MenuBuilderDelegate` with `switchAccount(_:)` + `saveCurrentAs(_:)`. Per non-active account card, appends `↪ Switch to <label>` action item (flags stale tokens with `(stale — needs re-login)`). Bottom menu: `Save current login as…`.
  - `AppDelegate.swift`: implemented both handlers. Stale-token pre-flight uses NSAlert. Errors surface via `showError`.
- **Built + installed**: `swift build` clean. `scripts/install_launchagent.sh` rebuilt + bootstrapped LaunchAgent. Manual click test confirmed end-to-end swap (verified by screenshot + Anthropic profile endpoint).
- **Docs**: README updated, `docs/account-switching.md` written with screenshot.

### In Progress

- Fix 2 (auto-rotation policy) — not started.

## Resume Here

1. **Implement `ClaudeDock/RotationPolicy.swift`** — pure function `decide(FetchResult, RotationConfig, lastRotateAt: Date?) -> Decision { case stay; case switchTo(id: String, reason: String) }`. Use scoring:

   ```
   score(account, horizon = 2h):
     rem5h = 100 - five_hour.utilization
     rem7d = 100 - seven_day.utilization
     ttr5h = secondsUntil(five_hour.resets_at)
     if rem7d <= 0: return -Infinity      # weekly cap absolute
     effective5h = (ttr5h <= horizon) ? 100 : rem5h
     return min(effective5h, rem7d)        # weakest constraint wins

   Decision:
     current = active account
     best    = argmax score(a) over accounts where a.error == nil
     switch iff
       (current.5h_util ≥ 95 OR current.7d_util ≥ 90)        # threshold gate
       AND score(best) ≥ score(current) + 15                  # hysteresis pp
       AND now - lastRotateAt ≥ 600s                          # cooldown
       AND best.id ≠ current.id
   ```

2. **TDD** the policy via `Tests/RotationPolicyTests/` (Swift XCTest). Cases:
   - both healthy → stay
   - current at 96% 5h, other at 20% → switch
   - current at 96%, other at 91% → stay (insufficient gap)
   - both 7d ≥ 90 → stay, reason="all saturated"
   - cooldown active → stay
   - candidate has error → skip, fall through to next
   - current 99% 5h but reset in < 2h → treat as refill imminent, don't switch

3. **Extend `Models.swift`** with `RotationConfig { enabled, high5h=95, high7d=90, hysteresisPp=15, cooldownSec=600, horizonSec=7200 }`. Append to `AppConfig` (back-compat: missing block = disabled).

4. **Hook in `AppDelegate.refresh()`** — after `fetchUsage` result, if `config.rotation.enabled`, call `RotationPolicy.decide`. On `.switchTo`: call `AccountSwitcher.switchTo`, persist `lastRotateAt`, post `NSUserNotification` ("Rotated → <label>. Restart claude to pick up.").

5. **Menu toggle** in `MenuBuilder` — "Auto-rotate" checkbox, surface current decision/next-reset readout.

6. **Kill switch** — read `CLAUDEDOCK_AUTO_ROTATE=0` env var in `RotationPolicy.decide` shortcut.

## Decisions (do NOT revisit)

- **Architecture: extend ClaudeDock, NOT a separate HTTP proxy.** Local Node/Bun proxy with `ANTHROPIC_BASE_URL` rewrite was the initial proposal — rejected because ClaudeDock already swaps the keychain entry Claude Code reads at session start. A proxy would duplicate auth handling and add a network hop for zero benefit.
- **Thresholds: Conservative 5h≥95%, 7d≥90%.** Hysteresis 15pp. Cooldown 10min. User-chosen.
- **Scoring: time + token combined.** `min(effective5h, rem7d)` where imminent 5h reset is treated as full refill. Pure-lowest-util and round-robin both rejected.
- **Mid-session: don't interrupt.** Keychain swap takes effect on next `claude` launch. Running PIDs hold tokens in memory and continue on old account until exit. Auto-restart of running `claude` PIDs rejected — destroys in-flight work.
- **Codex bridge: out of scope** for now. Claude OAuth slots only.
- **Identity ground truth = Anthropic `/api/oauth/profile`**, not blob bytes or labels. ClaudeDock labels can drift; always verify via API before trusting.

## Gotchas

- **Refresh tokens die silently.** OAuth refresh on a long-idle slot can fail → `UsageService` flags `needsReLogin`. Switch UI must pre-flight check cache for `error == .needsReLogin` and warn before writing the dead blob. Implemented.
- **`AccountSwitcher.mirrorFileFallbackIfPresent` only writes `~/.claude/.credentials.json` if file already exists.** On keychain-only installs (Claude Code 2.1.x) the file is absent → no fallback runs. That's correct; easy to misread as "swap didn't persist."
- **`security add-generic-password -w <blob>`** exposes the blob to `ps` for ~ms. Acceptable per existing `AccountStore` comment. Don't "fix" without explicit request.
- **Multiple `claude` PIDs run concurrently.** Each holds tokens in memory. Keychain swap does NOT affect running sessions — only new `claude` invocations.
- **Codex weekly limit can hit 100%** independently. Surface separately; not relevant to Claude rotation.
- **`docs/` was previously gitignored** ("contain auth/API details"). Sanitized this turn; gitignore entry removed.

## Context

- **Branch**: `main` (only Fix 1 commits pending)
- **Build**: `swift build` (Swift 5.9 package, macOS 13+, target `ClaudeDock`)
- **Tests**: none in repo. Fix 2 should add `Tests/RotationPolicyTests/` (Swift XCTest).
- **Logs**: `~/Library/Logs/ClaudeDock/stderr.log` (usage fetch errors, 429 spam)
- **LaunchAgent**: `~/Library/LaunchAgents/com.claudedock.ClaudeDock.plist` (auto-loaded, plist label kept since installer hard-codes it)
- **Prior specs**: `docs/plans/2026-04-20-multi-account-tracking.md`, `docs/specs/2026-04-20-multi-account-tracking-design.md`, `docs/specs/2026-04-22-live-account-reconciliation.md`.

## Unknowns (verify before acting)

- Whether the running launchd-loaded instance picks up `claudedock.json` edits at runtime. `UsageService.loadConfig` runs once at `applicationDidFinishLaunching`; restart via `launchctl unload/load` is likely needed for config-only changes.
- Whether Swift 5.9 toolchain is present (`Package.swift` declares `swift-tools-version: 5.9`). Run `swift --version` first.
- Auto-rotation kill-switch surface preference — env var, menu toggle, or both.
