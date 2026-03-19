import Foundation

struct RateLimitInfo: Codable {
    let utilization: Double
    let resets_at: String?
}

struct UsageLimits: Codable {
    let five_hour: RateLimitInfo?
    let seven_day: RateLimitInfo?
    let seven_day_sonnet: RateLimitInfo?
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
    let limits: UsageLimits?
    let stale: Bool
    let error: FetchError?
}

struct AppConfig: Codable {
    var refreshInterval: Int

    static let defaultConfig = AppConfig(refreshInterval: 30)
}
