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
        var cached = loadCache() ?? CacheEntry(
            accounts: [:],
            codexMetrics: nil,
            timestamp: Date().timeIntervalSince1970 * 1000
        )
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
        if let c = cache, c.backoff {
            let ageSec = Date().timeIntervalSince1970 - c.timestamp / 1000
            if ageSec < backoffSeconds {
                return AccountUsage(account: account, limits: c.data,
                                    error: .rateLimited, stale: true)
            }
        }

        let blob: String
        do {
            blob = try AccountStore.loadBundle(label: account.label)
        } catch {
            return AccountUsage(account: account, limits: cache?.data,
                                error: .noKey, stale: cache?.data != nil)
        }

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

    // MARK: - Codex metrics (unchanged logic from previous version)

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
