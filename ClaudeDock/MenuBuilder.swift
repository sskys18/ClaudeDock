import Cocoa

@objc protocol MenuBuilderDelegate: AnyObject {
    func refreshNow()
    func changeInterval(_ sender: NSMenuItem)
    func saveCurrentAs()
    func switchTo(_ sender: NSMenuItem)
    func renameAccount(_ sender: NSMenuItem)
    func deleteAccount(_ sender: NSMenuItem)
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

        if result.accounts.isEmpty {
            let none = NSMenuItem(title: "No accounts saved. Log in to Claude Code, then use Save below.",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for usage in result.accounts {
                let isActive = (result.activeAccountId == usage.account.id)
                menu.addItem(buildAccountRow(usage: usage, active: isActive))
            }
        }
        if let codex = result.codexMetrics {
            menu.addItem(buildCodexRow(codex: codex))
        }
        menu.addItem(.separator())

        let save = NSMenuItem(title: "Save current login as…",
                              action: #selector(MenuBuilderDelegate.saveCurrentAs),
                              keyEquivalent: "s")
        save.target = delegate
        menu.addItem(save)

        if !result.accounts.isEmpty {
            let switchItem = NSMenuItem(title: "Switch active login", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for usage in result.accounts {
                let isActive = (result.activeAccountId == usage.account.id)
                let s = NSMenuItem(
                    title: usage.account.label + (isActive ? " (active)" : ""),
                    action: #selector(MenuBuilderDelegate.switchTo(_:)),
                    keyEquivalent: "")
                s.target = delegate
                s.representedObject = usage.account.id
                if isActive { s.state = .on }
                sub.addItem(s)
            }
            switchItem.submenu = sub
            menu.addItem(switchItem)

            let manage = NSMenuItem(title: "Manage accounts", action: nil, keyEquivalent: "")
            let mSub = NSMenu()
            for usage in result.accounts {
                let per = NSMenuItem(title: usage.account.label, action: nil, keyEquivalent: "")
                let perSub = NSMenu()
                let ren = NSMenuItem(title: "Rename…",
                    action: #selector(MenuBuilderDelegate.renameAccount(_:)),
                    keyEquivalent: "")
                ren.target = delegate
                ren.representedObject = usage.account.id
                perSub.addItem(ren)
                let del = NSMenuItem(title: "Delete",
                    action: #selector(MenuBuilderDelegate.deleteAccount(_:)),
                    keyEquivalent: "")
                del.target = delegate
                del.representedObject = usage.account.id
                perSub.addItem(del)
                per.submenu = perSub
                mSub.addItem(per)
            }
            manage.submenu = mSub
            menu.addItem(manage)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "↻ Refresh",
            action: #selector(MenuBuilderDelegate.refreshNow),
            keyEquivalent: "r")
        refresh.target = delegate
        menu.addItem(refresh)

        let autoRefresh = NSMenuItem(title: "Auto-refresh: \(formatInterval(currentInterval))",
                                     action: nil, keyEquivalent: "")
        let autoSub = NSMenu()
        for seconds in [15, 30, 60, 120, 300] {
            let subItem = NSMenuItem(title: formatInterval(seconds),
                action: #selector(MenuBuilderDelegate.changeInterval(_:)),
                keyEquivalent: "")
            subItem.target = delegate
            subItem.tag = seconds
            if seconds == currentInterval { subItem.state = .on }
            autoSub.addItem(subItem)
        }
        autoRefresh.submenu = autoSub
        menu.addItem(autoRefresh)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeDock",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let footer = NSMenuItem(title: footerText(result), action: nil, keyEquivalent: "")
        footer.isEnabled = false
        menu.addItem(footer)

        return menu
    }

    private func buildAccountRow(usage: AccountUsage, active: Bool) -> NSMenuItem {
        let dot = active ? "●" : "○"
        let title: String
        if let err = usage.error, usage.limits == nil {
            let reason: String
            switch err {
            case .noKey: reason = "no credentials"
            case .needsReLogin: reason = "re-login required"
            case .rateLimited: reason = "rate limited"
            case .apiError: reason = "api error"
            }
            title = "\(dot) \(usage.account.label) · \(reason)"
        } else {
            let five = formatPercent(usage.limits?.five_hour?.utilization)
            let week = formatPercent(usage.limits?.seven_day?.utilization)
            let staleTag = usage.stale ? " (cached)" : ""
            title = "\(dot) \(usage.account.label) · 5h \(five) · 7d \(week)\(staleTag)"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func buildCodexRow(codex: CodexMetrics) -> NSMenuItem {
        let five = formatPercent(codex.five_hour_limit_pct)
        let week = formatPercent(codex.weekly_limit_pct)
        let item = NSMenuItem(title: "  Codex · 5h \(five) · 7d \(week)",
                              action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func footerText(_ result: FetchResult) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "Last refreshed: \(f.string(from: result.refreshedAt))"
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f%%", min(100, max(0, v)))
    }

    private func formatInterval(_ s: Int) -> String {
        s < 60 ? "\(s)s" : "\(s / 60)m"
    }
}
