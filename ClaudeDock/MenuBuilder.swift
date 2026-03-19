import Cocoa

class MenuBuilder {
    weak var delegate: MenuBuilderDelegate?
    private var currentInterval: Int

    init(currentInterval: Int) {
        self.currentInterval = currentInterval
    }

    func buildMenu(from result: FetchResult) -> NSMenu {
        let menu = NSMenu()

        if let limits = result.limits {
            // 5-Hour
            if let fiveHour = limits.five_hour {
                let resetText = formatReset(fiveHour.resets_at, style: .countdown)
                let view = UsageItemView(
                    title: "5-Hour Limit",
                    utilization: fiveHour.utilization,
                    resetText: resetText
                )
                let item = NSMenuItem()
                item.view = view
                menu.addItem(item)
                menu.addItem(.separator())
            }

            // 7-Day
            if let sevenDay = limits.seven_day {
                let resetText = formatReset(sevenDay.resets_at, style: .date)
                let view = UsageItemView(
                    title: "7-Day Limit",
                    utilization: sevenDay.utilization,
                    resetText: resetText
                )
                let item = NSMenuItem()
                item.view = view
                menu.addItem(item)
                menu.addItem(.separator())
            }

            // 7-Day Sonnet
            if let sonnet = limits.seven_day_sonnet {
                let resetText = formatReset(sonnet.resets_at, style: .date)
                let view = UsageItemView(
                    title: "7-Day Sonnet",
                    utilization: sonnet.utilization,
                    resetText: resetText
                )
                let item = NSMenuItem()
                item.view = view
                menu.addItem(item)
                menu.addItem(.separator())
            }

            // Plan type
            let planType = limits.seven_day != nil ? "Max" : "Pro"
            let planItem = NSMenuItem(title: "Plan: \(planType)", action: nil, keyEquivalent: "")
            planItem.isEnabled = false
            menu.addItem(planItem)
            menu.addItem(.separator())

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
            menu.addItem(.separator())
        } else {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if result.stale {
            let staleItem = NSMenuItem(title: "⚠ Using cached data", action: nil, keyEquivalent: "")
            staleItem.isEnabled = false
            menu.addItem(staleItem)
            menu.addItem(.separator())
        }

        // Refresh Now
        let refreshItem = NSMenuItem(title: "↻ Refresh Now", action: #selector(MenuBuilderDelegate.refreshNow), keyEquivalent: "r")
        refreshItem.target = delegate
        menu.addItem(refreshItem)

        // Auto-refresh submenu
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

        // Quit
        let quitItem = NSMenuItem(title: "Quit ClaudeDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    func updateInterval(_ seconds: Int) {
        currentInterval = seconds
    }

    // MARK: - Formatting

    private enum ResetStyle { case countdown, date }

    private func formatReset(_ isoDate: String?, style: ResetStyle) -> String {
        guard let isoDate, !isoDate.isEmpty else { return "" }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoDate) ?? ISO8601DateFormatter().date(from: isoDate) else {
            return ""
        }

        let now = Date()
        if date <= now {
            return "Resetting..."
        }

        switch style {
        case .countdown:
            let diff = Calendar.current.dateComponents([.hour, .minute], from: now, to: date)
            let h = diff.hour ?? 0
            let m = diff.minute ?? 0
            if h > 0 {
                return "Resets in \(h)h \(m)m"
            }
            return "Resets in \(m)m"
        case .date:
            let df = DateFormatter()
            df.dateFormat = "MMM d"
            return "Resets \(df.string(from: date))"
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
