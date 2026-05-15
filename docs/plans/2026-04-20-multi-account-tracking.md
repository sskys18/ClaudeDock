# Plan: Multi-Account Tracking & Lossless Account Switching

Date: 2026-04-20
Spec: `docs/specs/2026-04-20-multi-account-tracking-design.md`
Status: **Shipped 2026-04-21** — all phases complete, fast-forward merged to `main`, `feat/multi-account` deleted.

Final commit sequence on main:
- `4a3e379` feat(models): add AccountRef, AccountUsage, per-account cache
- `e479779` feat(accounts): AccountStore
- `3b65c6f` feat(accounts): OAuthRefresher (form-encoded, best-effort)
- `c0c71ce` feat(usage): per-account fetch loop
- `2344b31` feat(accounts): AccountSwitcher
- `d4b1d24` feat(app): multi-account menu + delegate; remove KeychainReader
- `7b9e698` feat(ui): columned rows + compact bar title with logo

UI polish applied during smoke (not originally in plan): tab-aligned columns, colored dots per percent, bold active label, monospaced-digit font, SF Symbol `bolt.fill` + `H | D` compact bar title.

## Overview

Add support for tracking two Claude accounts + one Codex account
simultaneously, with lossless in-app account switching that
sidesteps `/login` (which invalidates MCP OAuth sessions).

The plan has seven phases. Phase 0 is a set of spikes that gate
every later phase; do not start Phase 1 until Phase 0 findings are
appended to the spec as an appendix.

Absolute path prefixes used below:
- Repo: `<repo>`
- Swift sources: `<repo>/ClaudeDock`
- Scripts: `<repo>/scripts`

Commits land on branch `feat/multi-account`. One commit per completed task unless noted.

---

## Phase 0 — Spikes

### Task 0.1 — Create working branch

```
cd <repo>
git checkout -b feat/multi-account
```

Verify: `git branch --show-current` prints `feat/multi-account`.

### Task 0.2 — Dump Claude Code-credentials attributes

Run:

```
security find-generic-password -s "Claude Code-credentials" 2>&1 \
  | tee /tmp/claudedock-spike-attrs.txt
```

Capture and note these fields from the output:
- `"acct"<blob>=...` — the account string (likely the Anthropic user id / email)
- `"agrp"<blob>=...` — access group
- `"cdat"` / `"mdat"` — create / modify dates (ignore)
- Anything with `ACL` or `partition_list`

Also run:

```
security find-generic-password -s "Claude Code-credentials" -g 2>&1 \
  | head -20
```

to check whether macOS prompts (it will once, to authorize
`security` for read). If a prompt appears asking for the user's
login password, click "Always Allow".

Record findings in `/tmp/claudedock-spike-attrs.txt`.

### Task 0.3 — Test attr-preserving swap

With Account A currently active, save its blob:

```
security find-generic-password -s "Claude Code-credentials" -w \
  > /tmp/claudedock-spike-blobA.txt
ACCT=$(security find-generic-password -s "Claude Code-credentials" 2>&1 \
  | awk -F'"' '/"acct"<blob>=/ { print $4 }')
echo "acct=$ACCT"
```

Run `/login` with Account B to populate a distinct blob, save it:

```
security find-generic-password -s "Claude Code-credentials" -w \
  > /tmp/claudedock-spike-blobB.txt
```

Now simulate a ClaudeDock Switch that restores A preserving the
acct attribute:

```
security add-generic-password \
  -s "Claude Code-credentials" \
  -a "$ACCT" \
  -U \
  -w "$(cat /tmp/claudedock-spike-blobA.txt)"
```

In a **new** shell, read the blob back the way `KeychainReader`
does:

```
security find-generic-password -s "Claude Code-credentials" -w
```

Diff against `/tmp/claudedock-spike-blobA.txt`. Bytes must match.

Then launch Claude Code and confirm it treats Account A as logged
in (no `/login` prompt, authenticated commands work).

**Gate:** if Claude Code prompts for auth, the `-U` path does not
preserve ACL. Fall back: test the delete-plus-add alternative:

```
security delete-generic-password -s "Claude Code-credentials"
security add-generic-password \
  -s "Claude Code-credentials" \
  -a "$ACCT" \
  -T /usr/bin/security \
  -T /Applications/Claude.app \
  -w "$(cat /tmp/claudedock-spike-blobA.txt)"
```

Document which variant worked in the spec appendix.

### Task 0.4 — File-fallback behavior

Run:

```
ls -la ~/.claude/.credentials.json 2>&1
```

If absent: Claude Code currently uses keychain only; note this.

If present: temporarily move it aside and see if Claude Code still
authenticates from keychain:

```
mv ~/.claude/.credentials.json ~/.claude/.credentials.json.bak
# run any authenticated claude command, e.g.: claude --version or claude doctor
```

Restore:

```
mv ~/.claude/.credentials.json.bak ~/.claude/.credentials.json
```

Record whether Claude Code needs the file or not.

### Task 0.5 — OAuth refresh probe (best-effort)

Extract `refreshToken` from Account A's blob:

```
cat /tmp/claudedock-spike-blobA.txt \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("claudeAiOauth",{}).get("refreshToken",""))'
```

Try a refresh-token grant against the most plausible Anthropic
endpoint:

```
curl -sv -X POST https://console.anthropic.com/v1/oauth/token \
  -H "Content-Type: application/json" \
  -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$REFRESH\"}" \
  2>&1 | tee /tmp/claudedock-spike-refresh.txt
```

If 404: try `https://api.anthropic.com/v1/oauth/token` and
`https://auth.anthropic.com/oauth/token`. Capture response body
and status code in the appendix.

This spike may produce no usable endpoint. That is an acceptable
outcome: the implementation ships with the best-effort refresher,
and accounts fall through to `needsReLogin` on expiry.

### Task 0.6 — Append spike findings to spec

Edit `docs/specs/2026-04-20-multi-account-tracking-design.md`.
Append a new section at the end:

```markdown
## Appendix A — Spike Results (YYYY-MM-DD)

### A.1 Keychain attribute set observed
<paste relevant fields from /tmp/claudedock-spike-attrs.txt>

### A.2 Switch mechanism that worked
<"-U preserves ACL" OR "delete+add required, with -T flags X, Y">
Exact command: <paste>

### A.3 File fallback behavior
<"keychain-only install" OR ".credentials.json required, contents
mirror keychain blob">

### A.4 Refresh endpoint probe
Endpoint tried: <URL>
Status: <code>
Body: <first 200 chars>
Conclusion: <"refresh supported, body shape is X" OR "no endpoint
found, ship best-effort">
```

Commit:

```
git add docs/specs/2026-04-20-multi-account-tracking-design.md
git commit -m "docs(spec): append spike findings for multi-account work"
```

(Commits into gitignored `docs/` will be rejected; if so, skip the
`git add` and leave the spec local-only. No-op the commit.)

### Task 0.7 — Restore original active account

Restore whichever account the user wants active today (usually B,
whichever they use for daily work). Confirm Claude Code operates
normally before proceeding.

---

## Phase 1 — Models & Config migration

### Task 1.1 — Extend Models.swift

Replace the contents of
`<repo>/ClaudeDock/Models.swift` with:

```swift
import Foundation

enum PercentageSemantic {
    case utilization
    case remaining
}

struct RateLimitInfo: Codable {
    let utilization: Double
    let resets_at: String?
}

struct UsageLimits: Codable {
    let five_hour: RateLimitInfo?
    let seven_day: RateLimitInfo?
    let seven_day_sonnet: RateLimitInfo?
}

struct CodexMetrics: Codable, Equatable {
    let last_activity: String?
    let session_total_tokens: Double?
    let five_hour_limit_pct: Double?
    let weekly_limit_pct: Double?
    let five_hour_resets_at: Double?
    let weekly_resets_at: Double?
    let plan_type: String?

    var hasVisibleQuota: Bool {
        [five_hour_limit_pct, weekly_limit_pct]
            .compactMap { $0 }
            .contains { $0 > 0 }
    }
}

enum AccountKind: String, Codable {
    case claude
}

struct AccountRef: Codable, Equatable {
    let id: String
    var label: String
    let kind: AccountKind
}

enum FetchError: String, Codable {
    case noKey
    case rateLimited
    case apiError
    case needsReLogin
}

struct AccountUsage: Codable {
    let account: AccountRef
    var limits: UsageLimits?
    var error: FetchError?
    var stale: Bool
}

struct PerAccountCache: Codable {
    var data: UsageLimits?
    var timestamp: Double
    var backoff: Bool
    var error: FetchError?
}

struct CacheEntry: Codable {
    var accounts: [String: PerAccountCache]
    var codexMetrics: CodexMetrics?
    var timestamp: Double
}

struct FetchResult {
    let accounts: [AccountUsage]
    let codexMetrics: CodexMetrics?
    let refreshedAt: Date
    var activeAccountId: String?

    var hasAny: Bool {
        !accounts.isEmpty || codexMetrics != nil
    }
}

struct AppConfig: Codable {
    var refreshInterval: Int
    var accounts: [AccountRef]
    var activeAccountId: String?

    static let defaultConfig = AppConfig(
        refreshInterval: 30,
        accounts: [],
        activeAccountId: nil
    )

    enum CodingKeys: String, CodingKey {
        case refreshInterval
        case accounts
        case activeAccountId
    }

    init(refreshInterval: Int, accounts: [AccountRef], activeAccountId: String?) {
        self.refreshInterval = refreshInterval
        self.accounts = accounts
        self.activeAccountId = activeAccountId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.refreshInterval = (try? c.decode(Int.self, forKey: .refreshInterval)) ?? 30
        self.accounts = (try? c.decode([AccountRef].self, forKey: .accounts)) ?? []
        self.activeAccountId = try? c.decode(String?.self, forKey: .activeAccountId)
    }
}
```

Build:

```
cd <repo>
swift build 2>&1 | tail -40
```

Expected: many errors in `UsageService.swift`, `AppDelegate.swift`,
`MenuBuilder.swift` referencing the old `data` / `claudeLimits`
shape. This is expected and fixed in subsequent tasks.

Commit:

```
git add ClaudeDock/Models.swift
git commit -m "feat(models): add AccountRef, AccountUsage, per-account cache shape"
```

### Task 1.2 — Update UsageService.loadConfig / saveConfig

In `<repo>/ClaudeDock/UsageService.swift`,
the existing `loadConfig` and `saveConfig` already use JSONDecoder/
JSONEncoder over `AppConfig` and work unchanged because of the
custom `init(from:)`. No code change.

Write a manual sanity check script at
`/tmp/claudedock-configtest.sh`:

```
#!/usr/bin/env bash
set -eu
echo '{"refreshInterval":45}' > ~/.claude/claudedock.json.bak
cp ~/.claude/claudedock.json ~/.claude/claudedock.json.orig || true
echo '{"refreshInterval":45}' > ~/.claude/claudedock.json
cd <repo>
swift build 2>&1 | tail -5
# launch briefly and tail saved config
./.build/debug/ClaudeDock & PID=$!
sleep 3
kill $PID 2>/dev/null || true
cat ~/.claude/claudedock.json
mv ~/.claude/claudedock.json.orig ~/.claude/claudedock.json 2>/dev/null || rm ~/.claude/claudedock.json
```

Expected after run: config file contains `refreshInterval:45`,
`accounts:[]`, `activeAccountId:null`. Verify by eye.

---

## Phase 2 — AccountStore

### Task 2.1 — Create AccountStore.swift

Create
`<repo>/ClaudeDock/AccountStore.swift` with:

```swift
import Foundation

enum AccountStoreError: Error {
    case alreadyExists
    case notFound
    case keychainFailure(Int32, String)
    case decodeFailure
}

enum AccountStore {
    static let serviceNamePrefix = "ClaudeDock Account "
    static let claudeCodeService = "Claude Code-credentials"

    static func service(forLabel label: String) -> String {
        serviceNamePrefix + label
    }

    // MARK: - List

    static func listStoredLabels() -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["dump-keychain"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var labels: [String] = []
        for line in out.split(separator: "\n") {
            if let range = line.range(of: "\"svce\"<blob>=\"") {
                let tail = line[range.upperBound...]
                if let endQuote = tail.range(of: "\"") {
                    let service = String(tail[..<endQuote.lowerBound])
                    if service.hasPrefix(serviceNamePrefix) {
                        labels.append(String(service.dropFirst(serviceNamePrefix.count)))
                    }
                }
            }
        }
        return labels.sorted()
    }

    // MARK: - Read/Write our own bundles

    static func loadBundle(label: String) throws -> String {
        let data = try readPassword(service: service(forLabel: label))
        return data
    }

    static func saveBundle(label: String, blob: String, overwrite: Bool = false) throws {
        if !overwrite {
            if (try? readPassword(service: service(forLabel: label))) != nil {
                throw AccountStoreError.alreadyExists
            }
        }
        try writePassword(
            service: service(forLabel: label),
            account: "ClaudeDock",
            blob: blob
        )
    }

    static func rename(from oldLabel: String, to newLabel: String) throws {
        let blob = try loadBundle(label: oldLabel)
        try saveBundle(label: newLabel, blob: blob, overwrite: false)
        try deleteBundle(label: oldLabel)
    }

    static func deleteBundle(label: String) throws {
        try deletePassword(service: service(forLabel: label))
    }

    // MARK: - Read/Write Claude Code's slot

    static func readClaudeCodeBlob() throws -> (acct: String, blob: String) {
        let acct = readAccountAttr(service: claudeCodeService) ?? "claude"
        let blob = try readPassword(service: claudeCodeService)
        return (acct, blob)
    }

    static func writeClaudeCodeBlob(acct: String, blob: String) throws {
        try writePassword(service: claudeCodeService, account: acct, blob: blob)
    }

    // MARK: - security CLI helpers

    private static func readPassword(service: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe
        do { try proc.run() } catch {
            throw AccountStoreError.keychainFailure(-1, "launch failed")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if err.contains("could not be found") {
                throw AccountStoreError.notFound
            }
            throw AccountStoreError.keychainFailure(proc.terminationStatus, err)
        }
        let raw = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { throw AccountStoreError.notFound }
        if raw.allSatisfy({ $0.isHexDigit }), let decoded = hexDecode(raw) {
            return decoded
        }
        return raw
    }

    private static func readAccountAttr(service: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in out.split(separator: "\n") {
            if let range = line.range(of: "\"acct\"<blob>=\"") {
                let tail = line[range.upperBound...]
                if let endQuote = tail.range(of: "\"") {
                    return String(tail[..<endQuote.lowerBound])
                }
            }
        }
        return nil
    }

    private static func writePassword(service: String, account: String, blob: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "add-generic-password",
            "-s", service,
            "-a", account,
            "-U",
            "-w", blob
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        do { try proc.run() } catch {
            throw AccountStoreError.keychainFailure(-1, "launch failed")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AccountStoreError.keychainFailure(proc.terminationStatus, err)
        }
    }

    private static func deletePassword(service: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["delete-generic-password", "-s", service]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            throw AccountStoreError.keychainFailure(-1, "launch failed")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw AccountStoreError.notFound
        }
    }

    private static func hexDecode(_ hex: String) -> String? {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[i..<next], radix: 16) {
                bytes.append(b)
            }
            i = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
```

Build:

```
swift build 2>&1 | tail -20
```

Expected: compiles cleanly for the new file (other files still
break — that is fine, tracked to later tasks).

**Note on spike results:** if Phase 0 determined that `-U` does not
preserve ACL, before committing this task add `-T /usr/bin/security`
and `-T /Applications/Claude.app` to the `writePassword` arguments
list and preceed with a `delete-generic-password`. Mirror whatever
the spike showed works.

Commit:

```
git add ClaudeDock/AccountStore.swift
git commit -m "feat(accounts): AccountStore — keychain wrapper for per-account bundles"
```

### Task 2.2 — Parse helpers in Models.swift

Append to Models.swift:

```swift
struct ClaudeOAuthBlob {
    let raw: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    static func parse(_ raw: String) -> ClaudeOAuthBlob? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              !access.isEmpty else {
            return nil
        }
        let refresh = oauth["refreshToken"] as? String
        var exp: Date?
        if let ms = oauth["expiresAt"] as? Double {
            exp = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let s = oauth["expiresAt"] as? Int {
            exp = Date(timeIntervalSince1970: TimeInterval(s) / 1000.0)
        }
        return ClaudeOAuthBlob(
            raw: raw,
            accessToken: access,
            refreshToken: refresh,
            expiresAt: exp
        )
    }
}
```

Build:

```
swift build 2>&1 | tail -5
```

Commit:

```
git add ClaudeDock/Models.swift
git commit -m "feat(models): ClaudeOAuthBlob parser for keychain payload"
```

---

## Phase 3 — OAuthRefresher (opportunistic)

### Task 3.1 — Create OAuthRefresher.swift

Create
`<repo>/ClaudeDock/OAuthRefresher.swift` with:

```swift
import Foundation

enum OAuthRefreshError: Error {
    case noRefreshToken
    case networkError
    case endpointUnknown
    case decodeFailure
    case server(Int, String)
}

struct RefreshedBundle {
    let rawBlob: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

enum OAuthRefresher {
    // Endpoints ordered from most to least likely. First non-404
    // wins. Adjust from Phase 0 spike findings.
    static let candidateEndpoints: [URL] = [
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        URL(string: "https://api.anthropic.com/v1/oauth/token")!,
        URL(string: "https://auth.anthropic.com/oauth/token")!
    ]

    static func refresh(blob: String) async -> Result<RefreshedBundle, OAuthRefreshError> {
        guard let parsed = ClaudeOAuthBlob.parse(blob),
              let refresh = parsed.refreshToken,
              !refresh.isEmpty else {
            return .failure(.noRefreshToken)
        }

        for endpoint in candidateEndpoints {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            let body: [String: Any] = [
                "grant_type": "refresh_token",
                "refresh_token": refresh
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    continue
                }
                if http.statusCode == 404 {
                    continue
                }
                if !(200...299).contains(http.statusCode) {
                    return .failure(.server(http.statusCode,
                        String(data: data, encoding: .utf8) ?? ""))
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let newAccess = obj["access_token"] as? String else {
                    return .failure(.decodeFailure)
                }
                let newRefresh = (obj["refresh_token"] as? String) ?? refresh
                var newExp: Date?
                if let expIn = obj["expires_in"] as? Double {
                    newExp = Date().addingTimeInterval(expIn)
                }
                let newBlob = rewriteBlob(
                    original: blob,
                    accessToken: newAccess,
                    refreshToken: newRefresh,
                    expiresAt: newExp
                )
                return .success(RefreshedBundle(
                    rawBlob: newBlob,
                    accessToken: newAccess,
                    refreshToken: newRefresh,
                    expiresAt: newExp
                ))
            } catch {
                continue
            }
        }
        return .failure(.endpointUnknown)
    }

    private static func rewriteBlob(
        original: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date?
    ) -> String {
        guard let data = original.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = json["claudeAiOauth"] as? [String: Any] else {
            return original
        }
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        if let exp = expiresAt {
            oauth["expiresAt"] = exp.timeIntervalSince1970 * 1000
        }
        json["claudeAiOauth"] = oauth
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let str = String(data: out, encoding: .utf8) else {
            return original
        }
        return str
    }
}
```

If Phase 0 spike identified a working endpoint, reorder
`candidateEndpoints` so that one comes first. If none worked, leave
the list as-is; every refresh will fail through to
`.endpointUnknown`, which is acceptable.

Build:

```
swift build 2>&1 | tail -10
```

Commit:

```
git add ClaudeDock/OAuthRefresher.swift
git commit -m "feat(accounts): OAuthRefresher — best-effort refresh-token grant"
```

---

## Phase 4 — UsageService rewrite

### Task 4.1 — Per-account fetch loop

Replace
`<repo>/ClaudeDock/UsageService.swift` with:

```swift
import Foundation

class UsageService {
    private let cacheDir = NSHomeDirectory() + "/.claude"
    private let cachePath: String
    private let configPath: String
    private let backoffSeconds: TimeInterval = 300
    private let apiTimeout: TimeInterval = 5

    private var isFetching = false

    init() {
        cachePath = cacheDir + "/claudedock-cache.json"
        configPath = cacheDir + "/claudedock.json"
    }

    // MARK: - Config

    func loadConfig() -> AppConfig {
        guard let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .defaultConfig
        }
        return config
    }

    func saveConfig(_ config: AppConfig) {
        ensureCacheDir()
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        }
    }

    // MARK: - Fetch

    func fetchUsage(config: AppConfig) async -> FetchResult {
        let refreshedAt = Date()
        var cached = loadCache() ?? CacheEntry(accounts: [:], codexMetrics: nil,
                                               timestamp: Date().timeIntervalSince1970 * 1000)
        let codexMetrics = loadCodexMetrics() ?? cached.codexMetrics

        guard !isFetching else {
            return buildStaleResult(config: config, cache: cached,
                                    codex: codexMetrics, refreshedAt: refreshedAt)
        }
        isFetching = true
        defer { isFetching = false }

        var usages: [AccountUsage] = []
        for acct in config.accounts {
            let usage = await fetchOne(account: acct, cache: cached.accounts[acct.id])
            cached.accounts[acct.id] = PerAccountCache(
                data: usage.limits ?? cached.accounts[acct.id]?.data,
                timestamp: Date().timeIntervalSince1970 * 1000,
                backoff: usage.error == .rateLimited,
                error: usage.error
            )
            usages.append(usage)
        }

        cached.codexMetrics = codexMetrics
        cached.timestamp = Date().timeIntervalSince1970 * 1000
        saveCache(cached)

        return FetchResult(
            accounts: usages,
            codexMetrics: codexMetrics,
            refreshedAt: refreshedAt,
            activeAccountId: config.activeAccountId
        )
    }

    private func buildStaleResult(config: AppConfig, cache: CacheEntry,
                                  codex: CodexMetrics?, refreshedAt: Date) -> FetchResult {
        let accts = config.accounts.map { acct in
            AccountUsage(
                account: acct,
                limits: cache.accounts[acct.id]?.data,
                error: cache.accounts[acct.id]?.error,
                stale: true
            )
        }
        return FetchResult(
            accounts: accts,
            codexMetrics: codex,
            refreshedAt: refreshedAt,
            activeAccountId: config.activeAccountId
        )
    }

    private func fetchOne(account: AccountRef, cache: PerAccountCache?) async -> AccountUsage {
        // Backoff check
        if let c = cache, c.backoff {
            let ageSec = Date().timeIntervalSince1970 - c.timestamp / 1000
            if ageSec < backoffSeconds {
                return AccountUsage(account: account, limits: c.data,
                                    error: .rateLimited, stale: true)
            }
        }

        // Load blob
        let blob: String
        do {
            blob = try AccountStore.loadBundle(label: account.label)
        } catch {
            return AccountUsage(account: account, limits: cache?.data,
                                error: .noKey, stale: cache?.data != nil)
        }

        // Maybe refresh
        var currentBlob = blob
        if let parsed = ClaudeOAuthBlob.parse(blob),
           let exp = parsed.expiresAt,
           exp.timeIntervalSinceNow < 60 {
            let result = await OAuthRefresher.refresh(blob: blob)
            switch result {
            case .success(let refreshed):
                currentBlob = refreshed.rawBlob
                try? AccountStore.saveBundle(label: account.label,
                                             blob: refreshed.rawBlob,
                                             overwrite: true)
            case .failure:
                return AccountUsage(account: account, limits: cache?.data,
                                    error: .needsReLogin, stale: cache?.data != nil)
            }
        }

        guard let parsed = ClaudeOAuthBlob.parse(currentBlob) else {
            return AccountUsage(account: account, limits: cache?.data,
                                error: .noKey, stale: cache?.data != nil)
        }

        // HTTP fetch
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(parsed.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeDock/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = apiTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return AccountUsage(account: account, limits: cache?.data,
                                    error: .apiError, stale: cache?.data != nil)
            }
            if http.statusCode == 429 {
                return AccountUsage(account: account, limits: cache?.data,
                                    error: .rateLimited, stale: cache?.data != nil)
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return AccountUsage(account: account, limits: cache?.data,
                                    error: .needsReLogin, stale: cache?.data != nil)
            }
            guard http.statusCode == 200 else {
                return AccountUsage(account: account, limits: cache?.data,
                                    error: .apiError, stale: cache?.data != nil)
            }
            let limits = try JSONDecoder().decode(UsageLimits.self, from: data)
            return AccountUsage(account: account, limits: limits, error: nil, stale: false)
        } catch {
            return AccountUsage(account: account, limits: cache?.data,
                                error: .apiError, stale: cache?.data != nil)
        }
    }

    // MARK: - Cache

    private func loadCache() -> CacheEntry? {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else {
            return nil
        }
        return entry
    }

    private func saveCache(_ entry: CacheEntry) {
        ensureCacheDir()
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
        }
    }

    private func ensureCacheDir() {
        if !FileManager.default.fileExists(atPath: cacheDir) {
            try? FileManager.default.createDirectory(atPath: cacheDir,
                                                     withIntermediateDirectories: true)
        }
    }

    // MARK: - Codex metrics (unchanged logic, copied verbatim)

    private func loadCodexMetrics() -> CodexMetrics? {
        if let metrics = loadCodexMetricsFromOmx(), metrics.hasVisibleQuota {
            return metrics
        }
        if let metrics = loadCodexMetricsFromRollouts() {
            return metrics
        }
        return loadCodexMetricsFromOmx()
    }

    private func loadCodexMetricsFromOmx() -> CodexMetrics? {
        let metricsPath = workspaceRoot()
            .appendingPathComponent(".omx", isDirectory: true)
            .appendingPathComponent("metrics.json")
        guard let data = try? Data(contentsOf: metricsPath) else { return nil }
        return try? JSONDecoder().decode(CodexMetrics.self, from: data)
    }

    private func loadCodexMetricsFromRollouts() -> CodexMetrics? {
        var newestMetrics: CodexMetrics?
        var newestDate: Date?
        for sessionsDir in codexSessionsRoots() {
            guard let enumerator = FileManager.default.enumerator(
                at: sessionsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let rolloutFiles = enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
                .sorted { a, b in
                    let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return ad > bd
                }
            for f in rolloutFiles {
                guard let metrics = parseCodexMetrics(from: f) else { continue }
                let d = parseISO8601(metrics.last_activity) ?? .distantPast
                if newestDate == nil || d > newestDate! {
                    newestDate = d
                    newestMetrics = metrics
                }
            }
        }
        return newestMetrics
    }

    private func parseCodexMetrics(from rolloutFile: URL) -> CodexMetrics? {
        guard let data = try? Data(contentsOf: rolloutFile) else { return nil }
        let content = String(decoding: data, as: UTF8.self)
        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String, type == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String, payloadType == "token_count"
            else { continue }
            let info = payload["info"] as? [String: Any]
            let totalUsage = info?["total_token_usage"] as? [String: Any]
            let rateLimits = payload["rate_limits"] as? [String: Any]
            let primary = rateLimits?["primary"] as? [String: Any]
            let secondary = rateLimits?["secondary"] as? [String: Any]
            let m = CodexMetrics(
                last_activity: object["timestamp"] as? String,
                session_total_tokens: doubleValue(totalUsage?["total_tokens"]),
                five_hour_limit_pct: doubleValue(primary?["used_percent"]),
                weekly_limit_pct: doubleValue(secondary?["used_percent"]),
                five_hour_resets_at: doubleValue(primary?["resets_at"]),
                weekly_resets_at: doubleValue(secondary?["resets_at"]),
                plan_type: rateLimits?["plan_type"] as? String
            )
            if m.hasVisibleQuota { return m }
        }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private func codexSessionsRoots() -> [URL] {
        var roots: [URL] = []
        if let ch = ProcessInfo.processInfo.environment["CODEX_HOME"], !ch.isEmpty {
            roots.append(URL(fileURLWithPath: ch).appendingPathComponent("sessions", isDirectory: true))
        }
        roots.append(workspaceRoot()
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true))
        roots.append(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true))
        var unique: [URL] = []
        var seen = Set<String>()
        for r in roots where seen.insert(r.standardizedFileURL.path).inserted {
            unique.append(r)
        }
        return unique
    }

    private func parseISO8601(_ v: String?) -> Date? {
        guard let v, !v.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: v) ?? ISO8601DateFormatter().date(from: v)
    }

    private func workspaceRoot() -> URL {
        if let r = ProcessInfo.processInfo.environment["CLAUDEDOCK_WORKSPACE_ROOT"], !r.isEmpty {
            return URL(fileURLWithPath: r)
        }
        if let ch = ProcessInfo.processInfo.environment["CODEX_HOME"], !ch.isEmpty {
            return URL(fileURLWithPath: ch).deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
```

Note the signature change: `fetchUsage()` → `fetchUsage(config:)`
so callers must pass current config (no internal reload, avoids
double-read bugs when caller just wrote config).

Build:

```
swift build 2>&1 | tail -30
```

Expected errors now only in AppDelegate + MenuBuilder, fixed in
Phase 6.

Commit:

```
git add ClaudeDock/UsageService.swift
git commit -m "feat(usage): per-account fetch loop with opportunistic refresh"
```

---

## Phase 5 — AccountSwitcher

### Task 5.1 — Create AccountSwitcher.swift

Create
`<repo>/ClaudeDock/AccountSwitcher.swift`:

```swift
import Foundation

enum SwitcherError: Error {
    case duplicateLabel
    case notFound
    case keychainFailure(String)
    case noActiveLogin
}

struct AccountSwitcher {

    // MARK: - Save current login as a new account

    static func saveCurrentAs(label: String, config: inout AppConfig) throws {
        guard !label.isEmpty else { throw SwitcherError.duplicateLabel }
        if config.accounts.contains(where: { $0.label == label }) {
            throw SwitcherError.duplicateLabel
        }
        let current: (acct: String, blob: String)
        do {
            current = try AccountStore.readClaudeCodeBlob()
        } catch AccountStoreError.notFound {
            throw SwitcherError.noActiveLogin
        } catch {
            throw SwitcherError.keychainFailure("read active: \(error)")
        }
        do {
            try AccountStore.saveBundle(label: label, blob: current.blob,
                                        overwrite: false)
        } catch AccountStoreError.alreadyExists {
            throw SwitcherError.duplicateLabel
        } catch {
            throw SwitcherError.keychainFailure("save bundle: \(error)")
        }
        let ref = AccountRef(id: idFromLabel(label), label: label, kind: .claude)
        config.accounts.append(ref)
        config.activeAccountId = ref.id
    }

    // MARK: - Switch active

    static func switchTo(accountId: String, config: inout AppConfig) throws {
        guard let ref = config.accounts.first(where: { $0.id == accountId }) else {
            throw SwitcherError.notFound
        }
        let blob: String
        do {
            blob = try AccountStore.loadBundle(label: ref.label)
        } catch {
            throw SwitcherError.keychainFailure("load bundle: \(error)")
        }
        let acct = (try? AccountStore.readClaudeCodeBlob().acct) ?? "claude"
        do {
            try AccountStore.writeClaudeCodeBlob(acct: acct, blob: blob)
        } catch {
            throw SwitcherError.keychainFailure("write active: \(error)")
        }

        mirrorFileFallbackIfPresent(blob: blob)

        config.activeAccountId = accountId
    }

    // MARK: - Rename / delete

    static func rename(accountId: String, to newLabel: String,
                       config: inout AppConfig) throws {
        guard !newLabel.isEmpty else { throw SwitcherError.duplicateLabel }
        guard let idx = config.accounts.firstIndex(where: { $0.id == accountId }) else {
            throw SwitcherError.notFound
        }
        if config.accounts.contains(where: { $0.label == newLabel && $0.id != accountId }) {
            throw SwitcherError.duplicateLabel
        }
        let old = config.accounts[idx]
        do {
            try AccountStore.rename(from: old.label, to: newLabel)
        } catch {
            throw SwitcherError.keychainFailure("rename: \(error)")
        }
        config.accounts[idx].label = newLabel
    }

    static func delete(accountId: String, config: inout AppConfig) throws {
        guard let idx = config.accounts.firstIndex(where: { $0.id == accountId }) else {
            throw SwitcherError.notFound
        }
        let ref = config.accounts[idx]
        try? AccountStore.deleteBundle(label: ref.label)
        config.accounts.remove(at: idx)
        if config.activeAccountId == accountId {
            config.activeAccountId = nil
        }
    }

    // MARK: - Helpers

    private static func idFromLabel(_ label: String) -> String {
        let lowered = label.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        return String(lowered.filter { allowed.contains($0) })
    }

    private static func mirrorFileFallbackIfPresent(blob: String) {
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try blob.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        } catch {
            // Non-fatal; keychain write already succeeded.
        }
    }
}
```

Build:

```
swift build 2>&1 | tail -20
```

Commit:

```
git add ClaudeDock/AccountSwitcher.swift
git commit -m "feat(accounts): AccountSwitcher — save/switch/rename/delete"
```

---

## Phase 6 — Menu + AppDelegate

### Task 6.1 — Rewrite MenuBuilder.swift

Replace
`<repo>/ClaudeDock/MenuBuilder.swift` with:

```swift
import Cocoa

@objc protocol MenuBuilderDelegate: AnyObject {
    func refreshNow()
    func changeInterval(_ sender: NSMenuItem)
    func saveCurrentAs()
    func switchTo(_ sender: NSMenuItem)
    func renameAccount(_ sender: NSMenuItem)
    func deleteAccount(_ sender: NSMenuItem)
}

class MenuBuilder {
    weak var delegate: MenuBuilderDelegate?
    private var currentInterval: Int

    init(currentInterval: Int) {
        self.currentInterval = currentInterval
    }

    func updateInterval(_ seconds: Int) { currentInterval = seconds }

    func buildMenu(from result: FetchResult) -> NSMenu {
        let menu = NSMenu()

        // Per-account rows
        if result.accounts.isEmpty {
            let none = NSMenuItem(title: "No accounts saved. Log in to Claude Code, then:",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for usage in result.accounts {
                let isActive = (result.activeAccountId == usage.account.id)
                let item = buildAccountRow(usage: usage, active: isActive)
                menu.addItem(item)
            }
        }
        if let codex = result.codexMetrics {
            menu.addItem(buildCodexRow(codex: codex))
        }
        menu.addItem(.separator())

        // Save
        let save = NSMenuItem(title: "Save current login as…",
                              action: #selector(MenuBuilderDelegate.saveCurrentAs),
                              keyEquivalent: "s")
        save.target = delegate
        menu.addItem(save)

        // Switch submenu
        if !result.accounts.isEmpty {
            let switchItem = NSMenuItem(title: "Switch active login", action: nil,
                                        keyEquivalent: "")
            let sub = NSMenu()
            for usage in result.accounts {
                let isActive = (result.activeAccountId == usage.account.id)
                let s = NSMenuItem(
                    title: usage.account.label + (isActive ? " (active)" : ""),
                    action: #selector(MenuBuilderDelegate.switchTo(_:)),
                    keyEquivalent: "")
                s.target = delegate
                s.representedObject = usage.account.id
                if isActive { s.state = .on }
                sub.addItem(s)
            }
            switchItem.submenu = sub
            menu.addItem(switchItem)
        }

        // Manage submenu
        if !result.accounts.isEmpty {
            let manage = NSMenuItem(title: "Manage accounts", action: nil,
                                    keyEquivalent: "")
            let sub = NSMenu()
            for usage in result.accounts {
                let per = NSMenuItem(title: usage.account.label, action: nil,
                                     keyEquivalent: "")
                let perSub = NSMenu()
                let ren = NSMenuItem(title: "Rename…",
                    action: #selector(MenuBuilderDelegate.renameAccount(_:)),
                    keyEquivalent: "")
                ren.target = delegate
                ren.representedObject = usage.account.id
                perSub.addItem(ren)
                let del = NSMenuItem(title: "Delete",
                    action: #selector(MenuBuilderDelegate.deleteAccount(_:)),
                    keyEquivalent: "")
                del.target = delegate
                del.representedObject = usage.account.id
                perSub.addItem(del)
                per.submenu = perSub
                sub.addItem(per)
            }
            manage.submenu = sub
            menu.addItem(manage)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "↻ Refresh",
            action: #selector(MenuBuilderDelegate.refreshNow),
            keyEquivalent: "r")
        refresh.target = delegate
        menu.addItem(refresh)

        let autoRefresh = NSMenuItem(title: "Auto-refresh: \(formatInterval(currentInterval))",
                                     action: nil, keyEquivalent: "")
        let autoSub = NSMenu()
        for seconds in [15, 30, 60, 120, 300] {
            let subItem = NSMenuItem(title: formatInterval(seconds),
                action: #selector(MenuBuilderDelegate.changeInterval(_:)),
                keyEquivalent: "")
            subItem.target = delegate
            subItem.tag = seconds
            if seconds == currentInterval { subItem.state = .on }
            autoSub.addItem(subItem)
        }
        autoRefresh.submenu = autoSub
        menu.addItem(autoRefresh)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClaudeDock",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Footer
        let footer = NSMenuItem(title: footerText(result), action: nil, keyEquivalent: "")
        footer.isEnabled = false
        menu.addItem(footer)

        return menu
    }

    private func buildAccountRow(usage: AccountUsage, active: Bool) -> NSMenuItem {
        let dot = active ? "●" : "○"
        let title: String
        if let err = usage.error, usage.limits == nil {
            let reason: String
            switch err {
            case .noKey: reason = "no credentials"
            case .needsReLogin: reason = "re-login required"
            case .rateLimited: reason = "rate limited"
            case .apiError: reason = "api error"
            }
            title = "\(dot) \(usage.account.label) · \(reason)"
        } else {
            let five = formatPercent(usage.limits?.five_hour?.utilization)
            let week = formatPercent(usage.limits?.seven_day?.utilization)
            let staleTag = usage.stale ? " (cached)" : ""
            title = "\(dot) \(usage.account.label) · 5h \(five) · 7d \(week)\(staleTag)"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func buildCodexRow(codex: CodexMetrics) -> NSMenuItem {
        let five = formatPercent(codex.five_hour_limit_pct)
        let week = formatPercent(codex.weekly_limit_pct)
        let item = NSMenuItem(title: "  Codex · 5h \(five) · 7d \(week)",
                              action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func footerText(_ result: FetchResult) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "Last refreshed: \(f.string(from: result.refreshedAt))"
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f%%", min(100, max(0, v)))
    }

    private func formatInterval(_ s: Int) -> String {
        s < 60 ? "\(s)s" : "\(s / 60)m"
    }
}
```

Build:

```
swift build 2>&1 | tail -20
```

Expected: still a few errors in AppDelegate; fixed next task.

Commit:

```
git add ClaudeDock/MenuBuilder.swift
git commit -m "feat(menu): multi-account rows, switch + manage submenus"
```

### Task 6.2 — Rewrite AppDelegate.swift

Replace
`<repo>/ClaudeDock/AppDelegate.swift` with:

```swift
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, MenuBuilderDelegate {
    private var statusItem: NSStatusItem!
    private var usageService: UsageService!
    private var menuBuilder: MenuBuilder!
    private var refreshTimer: Timer?
    private var config: AppConfig!
    private var lastResult: FetchResult?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        usageService = UsageService()
        config = usageService.loadConfig()
        usageService.saveConfig(config) // persist migration defaults
        menuBuilder = MenuBuilder(currentInterval: config.refreshInterval)
        menuBuilder.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "--"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Task { await refresh() }
        startTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func refresh() async {
        let result = await usageService.fetchUsage(config: config)
        await MainActor.run {
            lastResult = result
            updateMenuBarTitle(result)
        }
    }

    private func updateMenuBarTitle(_ result: FetchResult) {
        let activeUsage = result.accounts.first(where: { $0.account.id == result.activeAccountId })
        let claude = activeUsage?.limits?.five_hour?.utilization.map(clamp)
        let codex = result.codexMetrics?.five_hour_limit_pct.map(clamp)

        if claude != nil || codex != nil {
            let c = claude.map { String(format: "%.0f%%", $0) } ?? "--"
            let x = codex.map { String(format: "%.0f%%", $0) } ?? "--"
            let usage = max(claude ?? 0, codex ?? 0)
            setBar("\(c) | \(x)", color: colorFor(usage))
        } else if !result.accounts.isEmpty {
            setBar("!", color: .systemRed)
        } else {
            setBar("--", color: .white)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let result = lastResult else {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        let built = menuBuilder.buildMenu(from: result)
        while built.items.count > 0 {
            let item = built.items[0]
            built.removeItem(item)
            menu.addItem(item)
        }
    }

    private func setBar(_ text: String, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    private func colorFor(_ pct: Double) -> NSColor {
        if pct > 80 { return .systemRed }
        if pct > 50 { return .systemYellow }
        return .systemGreen
    }

    private func clamp(_ v: Double) -> Double { min(100, max(0, v)) }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(config.refreshInterval), repeats: true
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    @objc private func didWake() { Task { await refresh() } }

    // MARK: - MenuBuilderDelegate

    @objc func refreshNow() { Task { await refresh() } }

    @objc func changeInterval(_ sender: NSMenuItem) {
        config.refreshInterval = sender.tag
        usageService.saveConfig(config)
        menuBuilder.updateInterval(sender.tag)
        startTimer()
    }

    @objc func saveCurrentAs() {
        let alert = NSAlert()
        alert.messageText = "Save current Claude login as…"
        alert.informativeText = "Enter a label (e.g. Work, Personal)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.placeholderString = "Label"
        alert.accessoryView = tf
        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }
        let label = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }

        do {
            try AccountSwitcher.saveCurrentAs(label: label, config: &config)
            usageService.saveConfig(config)
            Task { await refresh() }
        } catch {
            showError(error.localizedDescription, detail: "Could not save login.")
        }
    }

    @objc func switchTo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do {
            try AccountSwitcher.switchTo(accountId: id, config: &config)
            usageService.saveConfig(config)
            notifyRestartNeeded()
            Task { await refresh() }
        } catch {
            showError(error.localizedDescription, detail: "Switch failed.")
        }
    }

    @objc func renameAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let ref = config.accounts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(ref.label)"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.stringValue = ref.label
        alert.accessoryView = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newLabel = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AccountSwitcher.rename(accountId: id, to: newLabel, config: &config)
            usageService.saveConfig(config)
            Task { await refresh() }
        } catch {
            showError(error.localizedDescription, detail: "Rename failed.")
        }
    }

    @objc func deleteAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let ref = config.accounts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete saved login \(ref.label)?"
        alert.informativeText = "This removes ClaudeDock's stored credentials for this account. Claude Code's current login is not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try AccountSwitcher.delete(accountId: id, config: &config)
            usageService.saveConfig(config)
            Task { await refresh() }
        } catch {
            showError(error.localizedDescription, detail: "Delete failed.")
        }
    }

    private func notifyRestartNeeded() {
        let alert = NSAlert()
        alert.messageText = "Active login switched"
        alert.informativeText = "Restart any running `claude` CLI to pick up the new identity."
        alert.runModal()
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = detail
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
```

Build:

```
swift build 2>&1 | tail -30
```

Expected: clean build. Any remaining errors → fix before
committing.

Commit:

```
git add ClaudeDock/AppDelegate.swift
git commit -m "feat(app): wire multi-account actions + active-account bar title"
```

### Task 6.3 — Remove now-unused code in KeychainReader

Edit
`<repo>/ClaudeDock/KeychainReader.swift`.
Delete `cachedToken` and `clearCache` since `UsageService` no
longer consults `KeychainReader`. Keep `getCredentials()` for any
legacy use (no callers now; flag for deletion in a follow-up) —
actually: since nothing calls it, delete the whole file.

```
rm <repo>/ClaudeDock/KeychainReader.swift
```

Then rebuild:

```
swift build 2>&1 | tail -10
```

Commit:

```
git add ClaudeDock/KeychainReader.swift
git commit -m "refactor(accounts): remove KeychainReader (superseded by AccountStore)"
```

---

## Phase 7 — Verification

### Task 7.1 — Static build & lint

```
cd <repo>
swift build 2>&1 | tee /tmp/claudedock-build.log | tail -20
```

Expected: `Build complete!` with zero warnings. If new warnings,
fix before proceeding.

### Task 7.2 — Manual smoke test matrix

Run the app:

```
./.build/debug/ClaudeDock &
PID=$!
```

Walk the following matrix. Abort on any failure.

| Scenario                                  | Expected                         |
|-------------------------------------------|----------------------------------|
| Fresh start, no accounts saved            | Menu says "No accounts saved."   |
| Log in as Account A, "Save as Work"       | Work row appears; 5h/7d render   |
| Log in as Account B, "Save as Personal"   | Both rows render; Personal active |
| Switch → Work                             | Work marked ●; restart prompt    |
| Restart claude CLI, run an auth cmd       | Works as Work identity           |
| Rename Work → Workplace                   | Row relabels; keychain renamed   |
| Delete Workplace                          | Row disappears; keychain deleted |
| Kill network, hit Refresh                 | Rows go stale with "(cached)"    |
| Wait 8h+ or force expiry (edit blob)      | Row becomes "re-login required"  |

Kill the running app:

```
kill $PID
```

### Task 7.3 — Re-run auth-impact snapshot

Confirm ClaudeDock Switch does not touch anything beyond the
Claude Code keychain entry:

```
<repo>/scripts/snapshot_claude_auth.sh pre-switch
# switch via ClaudeDock menu
<repo>/scripts/snapshot_claude_auth.sh post-switch
<repo>/scripts/diff_claude_auth.sh pre-switch post-switch
```

Expected diff: only `Claude Code-credentials` hash changes. No new
`mcp-needs-auth-cache.json` (this was only written by `/login`).
If `mcp-needs-auth-cache.json` appears, investigate — it means
Claude Code detects identity change at a layer the keychain swap
cannot hide.

### Task 7.4 — Update AGENTS.md / README

Add a short "Multi-account workflow" section to
`<repo>/README.md` describing:
- Save current login as…
- Switch active login ▸
- Known limitation: MCP servers (Slack, Google Drive) still
  require re-auth per identity; plugins themselves are unaffected.

```
git add README.md
git commit -m "docs: multi-account workflow + MCP re-auth caveat"
```

### Task 7.5 — Open PR

```
git push -u origin feat/multi-account
gh pr create --title "Multi-account tracking with lossless switching" \
  --body "$(cat <<'EOF'
## Summary
- Track 2 Claude + 1 Codex accounts simultaneously in the menu
- Save / switch / rename / delete Claude identities via keychain,
  sidestepping /login to avoid MCP session invalidation
- OAuth refresh is opportunistic; accounts fall through to
  needsReLogin on expiry if Anthropic's refresh contract is
  unavailable

## Test plan
- [ ] Smoke test matrix in docs/plans/2026-04-20-multi-account-tracking.md §7.2
- [ ] Auth-impact diff clean (§7.3)
- [ ] Manual: restart claude CLI post-switch, verify new identity
EOF
)"
```

---

## File Manifest

Created:
- `ClaudeDock/AccountStore.swift`
- `ClaudeDock/AccountSwitcher.swift`
- `ClaudeDock/OAuthRefresher.swift`
- `docs/plans/2026-04-20-multi-account-tracking.md` (this file)
- `scripts/snapshot_claude_auth.sh` (already committed)
- `scripts/diff_claude_auth.sh` (already committed)

Modified:
- `ClaudeDock/Models.swift`
- `ClaudeDock/UsageService.swift`
- `ClaudeDock/MenuBuilder.swift`
- `ClaudeDock/AppDelegate.swift`
- `README.md`

Deleted:
- `ClaudeDock/KeychainReader.swift`

## Spec Coverage Check

| Spec section                              | Task(s)                |
|-------------------------------------------|------------------------|
| Storage model (per-account keychain)      | 2.1, 2.2               |
| Save current login                        | 5.1 saveCurrentAs, 6.2 |
| Switch active                             | 5.1 switchTo, 6.2      |
| Rename / Delete                           | 5.1 rename/delete, 6.2 |
| Usage polling + refresh                   | 3.1, 4.1               |
| Cache schema per account                  | 1.1, 4.1               |
| Config migration (optional fields)        | 1.1, 1.2               |
| Active-account detection                  | 5.1, 6.2               |
| Menu layout                               | 6.1                    |
| File fallback (.credentials.json)         | 5.1 mirrorFileFallback |
| Pre-implementation spikes                 | 0.2, 0.3, 0.4, 0.5     |
| Verification artifacts                    | 7.3                    |

## YAGNI / Placeholder Audit

- No "TODO" / "TBD" / "similar to above" blocks.
- Every Swift file listed above has its complete contents given.
- The only deliberately permissive piece is
  `OAuthRefresher.candidateEndpoints`, which is acknowledged as
  reverse-engineered and isolated so it can be updated without
  rippling through the codebase.
