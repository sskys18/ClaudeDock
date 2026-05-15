import Foundation

public struct RotationConfig: Codable, Equatable {
    public var enabled: Bool
    public var high5h: Double
    public var high7d: Double
    public var hysteresisPp: Double
    public var cooldownSec: TimeInterval
    public var horizonSec: TimeInterval

    public static let defaultConfig = RotationConfig(
        enabled: false,
        high5h: 95,
        high7d: 90,
        hysteresisPp: 15,
        cooldownSec: 600,
        horizonSec: 7200
    )

    public init(
        enabled: Bool,
        high5h: Double,
        high7d: Double,
        hysteresisPp: Double,
        cooldownSec: TimeInterval,
        horizonSec: TimeInterval
    ) {
        self.enabled = enabled
        self.high5h = high5h
        self.high7d = high7d
        self.hysteresisPp = hysteresisPp
        self.cooldownSec = cooldownSec
        self.horizonSec = horizonSec
    }
}

public struct AccountSnapshot: Equatable {
    public let id: String
    public let util5h: Double?
    public let util7d: Double?
    public let reset5hAt: Date?
    public let hasError: Bool

    public init(
        id: String,
        util5h: Double?,
        util7d: Double?,
        reset5hAt: Date?,
        hasError: Bool
    ) {
        self.id = id
        self.util5h = util5h
        self.util7d = util7d
        self.reset5hAt = reset5hAt
        self.hasError = hasError
    }
}

public enum RotationDecision: Equatable {
    case stay(reason: String)
    case switchTo(id: String, reason: String)
}

public enum RotationPolicy {
    public static func decide(
        accounts: [AccountSnapshot],
        activeId: String?,
        config: RotationConfig,
        lastRotateAt: Date?,
        now: Date
    ) -> RotationDecision {
        if !config.enabled {
            return .stay(reason: "rotation disabled")
        }
        guard let activeId,
              let current = accounts.first(where: { $0.id == activeId })
        else {
            return .stay(reason: "no active account")
        }
        if let last = lastRotateAt, now.timeIntervalSince(last) < config.cooldownSec {
            return .stay(reason: "cooldown active")
        }

        let currentEff5h = effective5h(current, config: config, now: now)
        let currentU7 = current.util7d ?? 0
        let breached = currentEff5h >= config.high5h || currentU7 >= config.high7d
        if !breached {
            return .stay(reason: "thresholds not breached")
        }

        let candidates = accounts.filter { !$0.hasError && $0.id != activeId }
        guard !candidates.isEmpty else {
            return .stay(reason: "no healthy candidate")
        }

        // All accounts (current + candidates) saturated on 7d → no point switching
        let allSevenDaySaturated = ([current] + candidates).allSatisfy {
            ($0.util7d ?? 0) >= config.high7d
        }
        if allSevenDaySaturated {
            return .stay(reason: "all accounts saturated")
        }

        let currentScore = score(current, config: config, now: now)
        let scored = candidates.map { ($0, score($0, config: config, now: now)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else {
            return .stay(reason: "no healthy candidate")
        }
        if best.1 < currentScore + config.hysteresisPp {
            return .stay(reason: "candidate gap below hysteresis")
        }

        return .switchTo(id: best.0.id, reason: "5h saturated; candidate has headroom")
    }

    // MARK: - Helpers

    private static func effective5h(
        _ a: AccountSnapshot, config: RotationConfig, now: Date
    ) -> Double {
        guard let u5 = a.util5h else { return 0 }
        if let reset = a.reset5hAt, reset.timeIntervalSince(now) <= config.horizonSec {
            return 0 // imminent refill — treat as fresh
        }
        return u5
    }

    private static func score(
        _ a: AccountSnapshot, config: RotationConfig, now: Date
    ) -> Double {
        let u7 = a.util7d ?? 0
        let rem7d = 100 - u7
        if rem7d <= 0 { return -.infinity }
        let eff5h = effective5h(a, config: config, now: now)
        let rem5h = 100 - eff5h
        return min(rem5h, rem7d)
    }
}
