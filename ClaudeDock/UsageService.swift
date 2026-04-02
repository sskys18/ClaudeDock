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
        if let data = try? JSONEncoder().encode(config) {
            ensureCacheDir()
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    // MARK: - Fetch

    func fetchUsage() async -> FetchResult {
        let codexMetrics = loadCodexMetrics()

        guard !isFetching else {
            return FetchResult(
                claudeLimits: loadCache()?.data,
                codexMetrics: codexMetrics,
                stale: true,
                error: nil
            )
        }
        isFetching = true
        defer { isFetching = false }

        if let cached = loadCache() {
            let age = Date().timeIntervalSince1970 - cached.timestamp / 1000
            if cached.backoff && age < backoffSeconds {
                return FetchResult(
                    claudeLimits: cached.data,
                    codexMetrics: codexMetrics,
                    stale: true,
                    error: .rateLimited
                )
            }
        }

        guard let token = KeychainReader.getCredentials() else {
            return FetchResult(
                claudeLimits: nil,
                codexMetrics: codexMetrics,
                stale: false,
                error: .noKey
            )
        }

        do {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("ClaudeDock/1.0.0", forHTTPHeaderField: "User-Agent")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.timeoutInterval = apiTimeout

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return fallbackToCache(error: .apiError, codexMetrics: codexMetrics)
            }

            if httpResponse.statusCode == 429 {
                saveCache(CacheEntry(data: loadCache()?.data, timestamp: Date().timeIntervalSince1970 * 1000, backoff: true))
                return fallbackToCache(error: .rateLimited, codexMetrics: codexMetrics)
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    KeychainReader.clearCache()
                }
                return FetchResult(
                    claudeLimits: nil,
                    codexMetrics: codexMetrics,
                    stale: false,
                    error: .apiError
                )
            }

            let limits = try JSONDecoder().decode(UsageLimits.self, from: data)
            saveCache(CacheEntry(data: limits, timestamp: Date().timeIntervalSince1970 * 1000, backoff: false))
            return FetchResult(
                claudeLimits: limits,
                codexMetrics: codexMetrics,
                stale: false,
                error: nil
            )
        } catch {
            return fallbackToCache(error: .apiError, codexMetrics: codexMetrics)
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
            try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        }
    }

    private func fallbackToCache(error: FetchError, codexMetrics: CodexMetrics?) -> FetchResult {
        if let cached = loadCache(), cached.data != nil {
            return FetchResult(
                claudeLimits: cached.data,
                codexMetrics: codexMetrics,
                stale: true,
                error: nil
            )
        }
        return FetchResult(
            claudeLimits: nil,
            codexMetrics: codexMetrics,
            stale: false,
            error: error
        )
    }

    // MARK: - Codex metrics

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

        guard let data = try? Data(contentsOf: metricsPath) else {
            return nil
        }

        return try? JSONDecoder().decode(CodexMetrics.self, from: data)
    }

    private func loadCodexMetricsFromRollouts() -> CodexMetrics? {
        let sessionsDir = codexSessionsRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let rolloutFiles = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        for rolloutFile in rolloutFiles {
            if let metrics = parseCodexMetrics(from: rolloutFile) {
                return metrics
            }
        }

        return nil
    }

    private func parseCodexMetrics(from rolloutFile: URL) -> CodexMetrics? {
        guard let data = try? Data(contentsOf: rolloutFile) else {
            return nil
        }
        let content = String(decoding: data, as: UTF8.self)

        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "token_count" else {
                continue
            }

            let info = payload["info"] as? [String: Any]
            let totalUsage = info?["total_token_usage"] as? [String: Any]
            let rateLimits = payload["rate_limits"] as? [String: Any]
            let primary = rateLimits?["primary"] as? [String: Any]
            let secondary = rateLimits?["secondary"] as? [String: Any]

            let primaryUsed = doubleValue(primary?["used_percent"])
            let secondaryUsed = doubleValue(secondary?["used_percent"])
            let primaryReset = doubleValue(primary?["resets_at"])
            let secondaryReset = doubleValue(secondary?["resets_at"])
            let totalTokens = doubleValue(totalUsage?["total_tokens"])
            let timestamp = object["timestamp"] as? String
            let planType = rateLimits?["plan_type"] as? String

            let metrics = CodexMetrics(
                last_activity: timestamp,
                session_total_tokens: totalTokens,
                five_hour_limit_pct: primaryUsed,
                weekly_limit_pct: secondaryUsed,
                five_hour_resets_at: primaryReset,
                weekly_resets_at: secondaryReset,
                plan_type: planType
            )

            if metrics.hasVisibleQuota {
                return metrics
            }
        }

        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private func codexSessionsRoot() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("sessions", isDirectory: true)
        }

        return workspaceRoot().appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private func workspaceRoot() -> URL {
        if let workspaceRoot = ProcessInfo.processInfo.environment["CLAUDEDOCK_WORKSPACE_ROOT"], !workspaceRoot.isEmpty {
            return URL(fileURLWithPath: workspaceRoot)
        }

        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
