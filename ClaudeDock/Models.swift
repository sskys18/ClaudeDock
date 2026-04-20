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
