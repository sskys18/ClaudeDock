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

struct CodexMetrics: Codable {
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

struct CacheEntry: Codable {
    let data: UsageLimits?
    let timestamp: Double
    let backoff: Bool
}

enum FetchError {
    case noKey
    case rateLimited
    case apiError
}

struct FetchResult {
    let claudeLimits: UsageLimits?
    let codexMetrics: CodexMetrics?
    let stale: Bool
    let error: FetchError?
}

struct AppConfig: Codable {
    var refreshInterval: Int

    static let defaultConfig = AppConfig(refreshInterval: 30)
}
