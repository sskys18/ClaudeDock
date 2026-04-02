import Cocoa

class MenuBuilder {
    weak var delegate: MenuBuilderDelegate?
    private var currentInterval: Int

    init(currentInterval: Int) {
        self.currentInterval = currentInterval
    }

    func buildMenu(from result: FetchResult) -> NSMenu {
        let menu = NSMenu()

        buildClaudeSection(into: menu, result: result)
        buildCodexSection(into: menu, result: result)

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

    // MARK: - Sections

    private func buildClaudeSection(into menu: NSMenu, result: FetchResult) {
        addSectionHeader("Claude", to: menu)

        if let limits = result.claudeLimits {
            if let fiveHour = limits.five_hour {
                addUsageRow(
                    title: "5-Hour Limit",
                    percent: fiveHour.utilization,
                    detailText: formatReset(fiveHour.resets_at),
                    semantics: .utilization,
                    to: menu
                )
            }

            if let sevenDay = limits.seven_day {
                addUsageRow(
                    title: "7-Day Limit",
                    percent: sevenDay.utilization,
                    detailText: formatReset(sevenDay.resets_at),
                    semantics: .utilization,
                    to: menu
                )
            }

            if let sonnet = limits.seven_day_sonnet {
                addUsageRow(
                    title: "7-Day Sonnet",
                    percent: sonnet.utilization,
                    detailText: formatReset(sonnet.resets_at),
                    semantics: .utilization,
                    to: menu
                )
            }

            let planType = limits.seven_day != nil ? "Max" : "Pro"
            let planItem = NSMenuItem(title: "Plan: \(planType)", action: nil, keyEquivalent: "")
            planItem.isEnabled = false
            menu.addItem(planItem)
        } else if let error = result.error {
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
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
    }

    private func buildCodexSection(into menu: NSMenu, result: FetchResult) {
        addSectionHeader("Codex", to: menu)

        guard let codexMetrics = result.codexMetrics, codexMetrics.hasVisibleQuota else {
            let item = NSMenuItem(title: "Codex metrics unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            return
        }

        if let fiveHour = codexMetrics.five_hour_limit_pct {
            addUsageRow(
                title: "5-Hour Limit",
                percent: fiveHour,
                detailText: formatCodexReset(codexMetrics.five_hour_resets_at, fallbackActivity: codexMetrics.last_activity),
                semantics: .utilization,
                to: menu
            )
        }

        if let weekly = codexMetrics.weekly_limit_pct {
            addUsageRow(
                title: "Weekly Limit",
                percent: weekly,
                detailText: formatCodexReset(codexMetrics.weekly_resets_at, fallbackActivity: codexMetrics.last_activity),
                semantics: .utilization,
                to: menu
            )
        }

        if let planType = codexMetrics.plan_type, !planType.isEmpty {
            let item = NSMenuItem(title: "Plan: \(planType.capitalized)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
    }

    private func addSectionHeader(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addUsageRow(title: String, percent: Double, detailText: String, semantics: PercentageSemantic, to menu: NSMenu) {
        let view = UsageItemView(
            title: title,
            percentage: percent,
            subtitle: detailText,
            semantic: semantics
        )
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
    }

    // MARK: - Formatting

    private func formatReset(_ isoDate: String?) -> String {
        guard let date = parseISO8601(isoDate) else { return "" }
        return formatResetDate(date)
    }

    private func formatCodexUpdate(_ isoDate: String?) -> String {
        guard let date = parseISO8601(isoDate) else {
            return "Local OMX metrics"
        }

        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "Updated just now"
        }
        if seconds < 3600 {
            return "Updated \(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "Updated \(seconds / 3600)h ago"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd HH:mm"
        return "Updated \(formatter.string(from: date))"
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
            return "Resetting..."
        }

        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: date)
        let d = diff.day ?? 0
        let h = diff.hour ?? 0
        let m = diff.minute ?? 0

        let countdown: String
        if d > 0 {
            countdown = "\(d)d \(h)h"
        } else if h > 0 {
            countdown = "\(h)h \(m)m"
        } else {
            countdown = "\(m)m"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd HH:mm"
        return "Resets in \(countdown) (\(formatter.string(from: date)))"
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
