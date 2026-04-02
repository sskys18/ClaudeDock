import Cocoa

class MenuBuilder {
    weak var delegate: MenuBuilderDelegate?
    private var currentInterval: Int

    init(currentInterval: Int) {
        self.currentInterval = currentInterval
    }

    func buildMenu(from result: FetchResult) -> NSMenu {
        let menu = NSMenu()

        let summaryItem = NSMenuItem()
        summaryItem.view = UsageSummaryView(
            rows: buildSummaryRows(from: result),
            footerText: buildFooterText(from: result)
        )
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        if let errorItem = buildClaudeErrorItem(from: result) {
            menu.addItem(errorItem)
            menu.addItem(.separator())
        }

        let refreshItem = NSMenuItem(title: "↻ Refresh", action: #selector(MenuBuilderDelegate.refreshNow), keyEquivalent: "r")
        refreshItem.target = delegate
        menu.addItem(refreshItem)

        let autoRefreshItem = NSMenuItem(title: "Auto-refresh: \(formatInterval(currentInterval))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for seconds in [15, 30, 60, 120, 300] {
            let label = formatInterval(seconds)
            let subItem = NSMenuItem(title: label, action: #selector(MenuBuilderDelegate.changeInterval(_:)), keyEquivalent: "")
            subItem.target = delegate
            subItem.tag = seconds
            if seconds == currentInterval {
                subItem.state = .on
            }
            submenu.addItem(subItem)
        }
        autoRefreshItem.submenu = submenu
        menu.addItem(autoRefreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ClaudeDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    func updateInterval(_ seconds: Int) {
        currentInterval = seconds
    }

    private func buildSummaryRows(from result: FetchResult) -> [UsageSummaryView.Row] {
        let claude = result.claudeLimits
        let codex = result.codexMetrics

        return [
            .init(
                label: "5H",
                claude: .init(
                    value: formatPercent(claude?.five_hour?.utilization),
                    subtitle: formatReset(claude?.five_hour?.resets_at),
                    color: colorForPercent(claude?.five_hour?.utilization)
                ),
                codex: .init(
                    value: formatPercent(codex?.five_hour_limit_pct),
                    subtitle: formatCodexReset(codex?.five_hour_resets_at, fallbackActivity: codex?.last_activity),
                    color: colorForPercent(codex?.five_hour_limit_pct)
                )
            ),
            .init(
                label: "7D",
                claude: .init(
                    value: formatClaudeWeekly(weekly: claude?.seven_day?.utilization, sonnet: claude?.seven_day_sonnet?.utilization),
                    subtitle: formatReset(claude?.seven_day?.resets_at),
                    color: colorForPercent(claude?.seven_day?.utilization)
                ),
                codex: .init(
                    value: formatPercent(codex?.weekly_limit_pct),
                    subtitle: formatCodexReset(codex?.weekly_resets_at, fallbackActivity: codex?.last_activity),
                    color: colorForPercent(codex?.weekly_limit_pct)
                )
            )
        ]
    }

    private func buildFooterText(from result: FetchResult) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let refreshed = formatter.string(from: result.refreshedAt)
        return "Last refreshed: \(refreshed)"
    }

    private func buildClaudeErrorItem(from result: FetchResult) -> NSMenuItem? {
        guard result.claudeLimits == nil, let error = result.error else {
            return nil
        }

        let errorText: String
        switch error {
        case .noKey:
            errorText = "No credentials found. Log in to Claude Code first."
        case .apiError:
            errorText = "Auth error — check Claude Code login"
        case .rateLimited:
            errorText = "Rate limited — using cached data"
        }

        let item = NSMenuItem(title: errorText, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value else { return "--" }
        let clamped = min(100, max(0, value))
        return String(format: "%.0f%%", clamped)
    }

    private func colorForPercent(_ value: Double?) -> NSColor {
        guard let value else { return .secondaryLabelColor }
        if value > 80 { return .systemRed }
        if value > 50 { return .systemYellow }
        return .systemGreen
    }

    private func formatPlan(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return "--" }
        return plan.capitalized
    }

    private func formatClaudeWeekly(weekly: Double?, sonnet: Double?) -> String {
        let weeklyText = formatPercent(weekly)
        guard let sonnet else { return weeklyText }
        return "\(weeklyText) (\(formatPercent(sonnet)))"
    }

    private func formatReset(_ isoDate: String?) -> String {
        guard let date = parseISO8601(isoDate) else { return "--" }
        return formatResetDate(date)
    }

    private func formatCodexUpdate(_ isoDate: String?) -> String {
        guard let date = parseISO8601(isoDate) else {
            return "--"
        }

        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd HH:mm"
        return formatter.string(from: date)
    }

    private func formatCodexReset(_ unixSeconds: Double?, fallbackActivity: String?) -> String {
        guard let unixSeconds else {
            return formatCodexUpdate(fallbackActivity)
        }

        return formatResetDate(Date(timeIntervalSince1970: unixSeconds))
    }

    private func parseISO8601(_ isoDate: String?) -> Date? {
        guard let isoDate, !isoDate.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: isoDate) ?? ISO8601DateFormatter().date(from: isoDate)
    }

    private func formatResetDate(_ date: Date) -> String {
        let now = Date()
        if date <= now {
            return "Resetting"
        }

        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: date)
        let d = diff.day ?? 0
        let h = diff.hour ?? 0
        let m = diff.minute ?? 0

        if d > 0 {
            return "\(d)d \(h)h"
        } else if h > 0 {
            return "\(h)h \(m)m"
        } else {
            return "\(m)m"
        }
    }

    private func formatInterval(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}

@objc protocol MenuBuilderDelegate: AnyObject {
    func refreshNow()
    func changeInterval(_ sender: NSMenuItem)
}
