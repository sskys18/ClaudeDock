import Cocoa

@objc protocol MenuBuilderDelegate: AnyObject {
    func refreshNow()
    func changeInterval(_ sender: NSMenuItem)
}

enum Palette {
    static let warnThreshold: Double = 50
    static let critThreshold: Double = 80

    static func color(for percent: Double?) -> NSColor {
        guard let v = percent else { return .tertiaryLabelColor }
        if v > critThreshold {
            return NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.38, alpha: 1)
        }
        if v > warnThreshold {
            return NSColor(calibratedRed: 0.98, green: 0.70, blue: 0.28, alpha: 1)
        }
        return NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.62, alpha: 1)
    }

    static let claudeTint: NSColor = .systemIndigo
    static let codexTint: NSColor = NSColor(calibratedRed: 0.66, green: 0.54, blue: 0.95, alpha: 1)
    static let activeDot: NSColor = .controlAccentColor
    static let mutedBar: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.14)
    static let bucketLabel: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
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

        menu.addItem(buildHeader(result))
        menu.addItem(.separator())

        if result.accounts.isEmpty {
            let none = NSMenuItem(title: "No accounts saved. Log in to Claude Code, then use Save below.",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for (idx, usage) in result.accounts.enumerated() {
                if idx > 0 { menu.addItem(.separator()) }
                let isActive = (result.activeAccountId == usage.account.id)
                menu.addItem(buildAccountRow(usage: usage, active: isActive))
            }
        }
        if let codex = result.codexMetrics {
            menu.addItem(.separator())
            menu.addItem(buildCodexRow(codex: codex))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeDock",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    private func buildHeader(_ result: FetchResult) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = HeaderView(
            refreshedAt: result.refreshedAt,
            currentInterval: currentInterval,
            delegate: delegate
        )
        return item
    }

    private func buildAccountRow(usage: AccountUsage, active: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false

        var errorMsg: String?
        if let err = usage.error, usage.limits == nil {
            switch err {
            case .noKey: errorMsg = "no credentials"
            case .needsReLogin: errorMsg = "re-login required"
            case .rateLimited: errorMsg = "rate limited"
            case .apiError: errorMsg = "api error"
            }
        }

        let fiveH: (Double?, Date?)? = errorMsg == nil
            ? (usage.limits?.five_hour?.utilization,
               usage.limits?.five_hour?.resets_at.flatMap(parseISO8601))
            : nil
        let sevenD: (Double?, Date?)? = errorMsg == nil
            ? (usage.limits?.seven_day?.utilization,
               usage.limits?.seven_day?.resets_at.flatMap(parseISO8601))
            : nil

        item.view = AccountCardView(
            title: usage.account.label,
            active: active,
            providerSymbol: nil,
            providerTint: nil,
            errorMsg: errorMsg,
            fiveH: fiveH,
            sevenD: sevenD
        )
        return item
    }

    private func buildCodexRow(codex: CodexMetrics) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = AccountCardView(
            title: "Codex",
            active: false,
            providerSymbol: "hexagon.fill",
            providerTint: Palette.codexTint,
            errorMsg: nil,
            fiveH: (codex.five_hour_limit_pct,
                    codex.five_hour_resets_at.map { Date(timeIntervalSince1970: $0) }),
            sevenD: (codex.weekly_limit_pct,
                     codex.weekly_resets_at.map { Date(timeIntervalSince1970: $0) })
        )
        return item
    }

    private func parseISO8601(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    private func smallFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    }

    private func formatInterval(_ s: Int) -> String {
        s < 60 ? "\(s)s" : "\(s / 60)m"
    }
}
