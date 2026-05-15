import XCTest
@testable import ClaudeDockCore

final class RotationPolicyTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_780_000_000)

    func config(enabled: Bool = true) -> RotationConfig {
        RotationConfig(
            enabled: enabled,
            high5h: 95,
            high7d: 90,
            hysteresisPp: 15,
            cooldownSec: 600,
            horizonSec: 7200
        )
    }

    func snap(
        _ id: String,
        u5: Double?,
        u7: Double?,
        reset5h: Date? = nil,
        err: Bool = false
    ) -> AccountSnapshot {
        AccountSnapshot(id: id, util5h: u5, util7d: u7, reset5hAt: reset5h, hasError: err)
    }

    // 1. Both healthy → stay
    func test_both_healthy_stays() {
        let r = RotationPolicy.decide(
            accounts: [snap("a", u5: 20, u7: 30), snap("b", u5: 10, u7: 25)],
            activeId: "a",
            config: config(),
            lastRotateAt: nil,
            now: now
        )
        XCTAssertEqual(r, .stay(reason: "thresholds not breached"))
    }

    // 2. Active saturated 5h, other has headroom → switch
    func test_switches_when_5h_saturated_and_candidate_has_headroom() {
        let r = RotationPolicy.decide(
            accounts: [snap("a", u5: 96, u7: 50), snap("b", u5: 20, u7: 30)],
            activeId: "a",
            config: config(),
            lastRotateAt: nil,
            now: now
        )
        XCTAssertEqual(r, .switchTo(id: "b", reason: "5h saturated; candidate has headroom"))
    }

    // 3. Active 96% 5h, other 91% 5h → insufficient gap → stay
    func test_stays_when_candidate_gap_below_hysteresis() {
        let r = RotationPolicy.decide(
            accounts: [snap("a", u5: 96, u7: 50), snap("b", u5: 91, u7: 50)],
            activeId: "a",
            config: config(),
            lastRotateAt: nil,
            now: now
        )
        XCTAssertEqual(r, .stay(reason: "candidate gap below hysteresis"))
    }

    // 4. All accounts 7d saturated → stay
    func test_stays_when_all_saturated() {
        let r = RotationPolicy.decide(
            accounts: [snap("a", u5: 96, u7: 91), snap("b", u5: 30, u7: 92)],
            activeId: "a",
            config: config(),
            lastRotateAt: nil,
            now: now
        )
        XCTAssertEqual(r, .stay(reason: "all accounts saturated"))
    }

    // 5. Cooldown active → stay
    func test_cooldown_blocks_switch() {
        let lastRotate = now.addingTimeInterval(-300) // 5min ago, cooldown is 10min
        let r = RotationPolicy.decide(
            accounts: [snap("a", u5: 96, u7: 50), snap("b", u5: 20, u7: 30)],
            activeId: "a",
            config: config(),
            lastRotateAt: lastRotate,
            now: now
        )
        XCTAssertEqual(r, .stay(reason: "cooldown active"))
    }

    // 6. Candidate has error → skip it
    func test_skips_errored_candidates() {
        let r = RotationPolicy.decide(
            accounts: [snap("a", u5: 96, u7: 50), snap("b", u5: 10, u7: 10, err: true)],
            activeId: "a",
            config: config(),
            lastRotateAt: nil,
            now: now
        )
        XCTAssertEqual(r, .stay(reason: "no healthy candidate"))
    }

    // 7. Active 99% 5h but reset within horizon → treat as imminent refill → stay
    func test_imminent_5h_reset_treated_as_refill() {
        let resetSoon = now.addingTimeInterval(1800) // 30min
        let r = RotationPolicy.decide(
            accounts: [
                snap("a", u5: 99, u7: 50, reset5h: resetSoon),
                snap("b", u5: 20, u7: 30),
            ],
            activeId: "a",
            config: config(),
            lastRotateAt: nil,
            now: now
        )
        // 7d isn't breached either, 5h treated as refill → thresholds not breached
        XCTAssertEqual(r, .stay(reason: "thresholds not breached"))
    }

    // 8. Disabled config → stay
    func test_disabled_config_always_stays() {
        let r = RotationPolicy.decide(
            accounts: [snap("a", u5: 99, u7: 99), snap("b", u5: 5, u7: 5)],
            activeId: "a",
            config: config(enabled: false),
            lastRotateAt: nil,
            now: now
        )
        XCTAssertEqual(r, .stay(reason: "rotation disabled"))
    }

    // 9. No active account → stay
    func test_no_active_stays() {
        let r = RotationPolicy.decide(
            accounts: [snap("a", u5: 50, u7: 50)],
            activeId: nil,
            config: config(),
            lastRotateAt: nil,
            now: now
        )
        XCTAssertEqual(r, .stay(reason: "no active account"))
    }
}
