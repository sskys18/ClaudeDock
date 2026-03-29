import Foundation

@MainActor
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
        // Debounce
        guard !isFetching else {
            return FetchResult(limits: loadCache()?.data, stale: true, error: nil)
        }
        isFetching = true
        defer { isFetching = false }

        // Check cache freshness
        if let cached = loadCache() {
            let age = Date().timeIntervalSince1970 - cached.timestamp / 1000
            if cached.backoff && age < backoffSeconds {
                return FetchResult(limits: cached.data, stale: true, error: .rateLimited)
            }
        }

        guard let token = KeychainReader.getCredentials() else {
            return FetchResult(limits: nil, stale: false, error: .noKey)
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
                return fallbackToCache(error: .apiError)
            }

            if httpResponse.statusCode == 429 {
                saveCache(CacheEntry(data: loadCache()?.data, timestamp: Date().timeIntervalSince1970 * 1000, backoff: true))
                return fallbackToCache(error: .rateLimited)
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    KeychainReader.clearCache()
                }
                return FetchResult(limits: nil, stale: false, error: .apiError)
            }

            let limits = try JSONDecoder().decode(UsageLimits.self, from: data)
            saveCache(CacheEntry(data: limits, timestamp: Date().timeIntervalSince1970 * 1000, backoff: false))
            return FetchResult(limits: limits, stale: false, error: nil)

        } catch {
            return fallbackToCache(error: .apiError)
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

    private func fallbackToCache(error: FetchError) -> FetchResult {
        if let cached = loadCache(), cached.data != nil {
            return FetchResult(limits: cached.data, stale: true, error: nil)
        }
        return FetchResult(limits: nil, stale: false, error: error)
    }
}
