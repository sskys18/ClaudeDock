# ClaudeDock

ClaudeDock is a lightweight macOS menu bar app that shows **Claude** and **Codex/GPT** quota status in one place.

It is designed to:
- stay in the macOS menu bar (`LSUIElement` app)
- reuse existing local auth/state instead of creating duplicate login flows
- auto-start at login through a **user LaunchAgent**
- show both Claude and Codex usage with compact menu bar text and richer dropdown details

## What it shows

### Menu bar title
The menu bar title shows:

```text
<Claude 5h used %> | <Codex 5h used %>
```

Example:

```text
18% | 20%
```

- left side = Claude 5-hour usage percent
- right side = Codex 5-hour usage percent
- no `A` / `C` prefixes

### Dropdown menu
The dropdown has two sections.

#### Claude
- 5-Hour Limit
- 7-Day Limit
- 7-Day Sonnet
- Plan

#### Codex
- 5-Hour Limit
- Weekly Limit
- Plan

Both Claude and Codex rows show reset timing when available.

The menu also includes:
- `↻ Refresh`
- auto-refresh interval picker
- `Quit ClaudeDock`

## Data sources

### Claude
Claude data comes from Anthropic usage APIs via the existing local Claude auth state.

Source path in code:
- `ClaudeDock/UsageService.swift`
- `ClaudeDock/KeychainReader.swift`

Auth behavior:
- reuses keychain/file-backed Claude credentials
- does **not** create a separate login flow
- avoids duplicate auth prompts after boot when local auth state already exists

### Codex / GPT
Codex data is local-only and does **not** use a separate network auth flow in this app.

The app reads Codex quota from:
1. `.omx/metrics.json`
2. if that is empty or `0/0`, fallback to latest `.codex/sessions/**/rollout-*.jsonl` `token_count` event

This fallback exists because OMX metrics can sometimes show `0/0` even when real Codex quota data is available in recent rollout files.

## Launch behavior

ClaudeDock is installed as a **user LaunchAgent**, not a system daemon.

### Installed files
- Binary:
  - `~/Library/Application Support/ClaudeDock/bin/ClaudeDock`
- LaunchAgent plist:
  - `~/Library/LaunchAgents/com.sskys.ClaudeDock.plist`
- Logs:
  - `~/Library/Logs/ClaudeDock/stdout.log`
  - `~/Library/Logs/ClaudeDock/stderr.log`

### LaunchAgent environment
The LaunchAgent sets:
- `CODEX_HOME=<repo>/.codex`
- `CLAUDEDOCK_WORKSPACE_ROOT=<repo root>`

This lets the installed binary continue reading the repository-local `.codex/` and `.omx/` state after login.

## Install / update

From the repository root:

```bash
./scripts/install_launchagent.sh
```

What it does:
1. builds the app in release mode
2. copies the binary into Application Support
3. writes/updates the LaunchAgent plist
4. bootstraps/restarts the LaunchAgent
5. updates global Codex status-line config

## Uninstall

```bash
./scripts/uninstall_launchagent.sh
```

This removes:
- the LaunchAgent plist
- the installed binary

## Codex status-line config

The installer updates:

```text
~/.codex/config.toml
```

Current `status_line` shape:

```toml
status_line = [ "model-name", "context-used", "context-window-size", "project-root", "git-branch", "five-hour-limit", "weekly-limit" ]
```

This is separate from ClaudeDock itself, but kept in sync by the installer.

## Project structure

### App code
- `ClaudeDock/AppDelegate.swift` — app lifecycle, refresh loop, menu bar title
- `ClaudeDock/UsageService.swift` — Claude fetch + Codex local metrics loading
- `ClaudeDock/MenuBuilder.swift` — dropdown menu construction
- `ClaudeDock/UsageItemView.swift` — usage row UI
- `ClaudeDock/Models.swift` — shared data models
- `ClaudeDock/KeychainReader.swift` — Claude auth reuse
- `ClaudeDock/ClaudeDockEntry.swift` — app entry point

### Scripts
- `scripts/install_launchagent.sh` — build/install/restart app + LaunchAgent
- `scripts/uninstall_launchagent.sh` — remove LaunchAgent + installed binary
- `scripts/configure_codex_statusline.py` — update `~/.codex/config.toml`

## Behavior notes
- Claude values are shown as **used** percentages.
- Codex values are also shown as **used** percentages.
- Codex rows now match Claude more closely by showing reset timing when available.
- The app refreshes both Claude and Codex when `Refresh` is clicked.
- The old `Using cached Claude data` banner has been removed.

## Verification commands

Build:

```bash
swift build
```

Reinstall + restart LaunchAgent:

```bash
./scripts/install_launchagent.sh
```

Check LaunchAgent status:

```bash
launchctl print gui/$(id -u)/com.sskys.ClaudeDock
```

## Current limitation
Codex values still depend on local Codex session/runtime artifacts existing. If there is no usable recent local Codex session data, Codex quota can still be unavailable.
